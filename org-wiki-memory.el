;;; org-wiki-memory.el --- Project and personal agent memory -*- lexical-binding: t; -*-

;;; Commentary:

;; Durable, scoped Org records for local agent hosts.  The host supplies
;; the canonical workspace and session.  No index is needed to read a write.

;;; Code:

(require 'org-wiki-mcp)
(require 'mcp-server-lib-commands)
(require 'seq)
(require 'subr-x)

(declare-function org-wiki-qmd--validate-node "org-wiki-qmd" (node))
(declare-function org-roam-db-query "org-roam-db")
(declare-function org-roam-db--file-title "org-roam-db")
(declare-function org-roam-db-node-p "org-roam-db")
(declare-function org-roam-file-p "org-roam" (&optional file))
(declare-function org-roam-db-update-file "org-roam-db")

(defcustom org-wiki-memory-max-links 5
  "Maximum number of Org-roam links to derive when saving a memory.
Explicit ID links take precedence over mentions of titles or aliases.
Set to zero to disable automatic links on new and revised memories."
  :type 'natnum
  :group 'org-wiki)

(defconst org-wiki-memory--filename-prefix
  "[0-9]\\{8\\}T[0-9]\\{6\\}Z-[a-f0-9]\\{12\\}-"
  "Regexp for the UTC timestamp and request-salted hash before the Org ID.")

(defconst org-wiki-memory--forgotten
  "Forgotten \\([[:xdigit:]]+\\)\\(?: \\([a-f0-9]\\{64\\}\\)\\)?\n\\'"
  "Tombstone containing the forget fingerprint and optional creation key.")

(defun org-wiki-memory--id-suffix (id)
  "Return the filename suffix for Org ID without letting it supply a path."
  (unless (and (stringp id) (not (string-empty-p id)) (equal (string-trim id) id)
               (not (string-match-p "[[:cntrl:]]" id)))
    (signal 'org-wiki-error '(:invalid_record)))
  (if (and (<= (string-bytes id) 200)
           (string-match-p "\\`[[:alnum:]_][[:alnum:]@_.:+-]*\\'" id))
      id
    ;; The leading ! keeps encoded suffixes distinct from literal IDs.
    (concat "!" (secure-hash 'sha256 id))))

(defun org-wiki-memory--field (data key &optional multiline)
  "Read nonempty string KEY from DATA, allowing MULTILINE text."
  (let ((value (alist-get key data)))
    (unless (and (stringp value) (not (string-empty-p (string-trim value)))
                 (<= (length value) (if multiline 16000 500))
                 (not (string-match-p (if multiline "[\0\r]" "[[:cntrl:]]") value)))
      (signal 'org-wiki-error (list :invalid_field key)))
    value))

(defun org-wiki-memory--directory (scope)
  "Resolve the managed directory for SCOPE without following nested links."
  (let* ((root (file-name-as-directory (file-truename org-wiki-root)))
         (dir (expand-file-name (concat "agent-memory/" scope) root)))
    (unless (equal dir (file-truename dir))
      (signal 'org-wiki-error '(:unsafe_path)))
    dir))

(defun org-wiki-memory--record (file)
  "Return the persisted record at FILE, including its revision."
  (when (file-symlink-p file) (signal 'org-wiki-error '(:unsafe_path)))
  (when (file-regular-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((revision (secure-hash 'sha256 (current-buffer))))
        (goto-char (point-min))
        (cond
         ((looking-at org-wiki-memory--forgotten)
          (list :forgotten (match-string 1)))
         ((looking-at ":PROPERTIES:$")
          (delay-mode-hooks (org-mode))
          (let ((id (org-entry-get nil "ID"))
                (kind (org-entry-get nil "WIKI_KIND"))
                (case-fold-search nil))
            (unless (and id
                         (string-match-p
                          (concat "\\`\\(?:" org-wiki-memory--filename-prefix "\\)?"
                                  (regexp-quote (org-wiki-memory--id-suffix id)) "\\'")
                          (file-name-base file))
                         (member kind org-wiki-memory-kinds))
              (signal 'org-wiki-error '(:invalid_record)))
            (append (list :kind kind)
                    (when-let* ((path (org-entry-get nil "SCRIPT_PATH")))
                      (list :script_path path :script_root (org-entry-get nil "SCRIPT_ROOT")))
                    (list :id id :revision revision :scope (org-entry-get nil "MEMORY_SCOPE")
                          :category (org-entry-get nil "CATEGORY")
                          :source (org-entry-get nil "MEMORY_SOURCE")
                          :updated (org-entry-get nil "UPDATED")
                          :updated_by (org-entry-get nil "UPDATED_BY")
                          :request (org-entry-get nil "LAST_REQUEST")
                          :title (org-wiki--file-title file)
                          :related_ids (vconcat (org-wiki--memory-relation-ids))
                          :summary (org-wiki-memory--section "Summary")
                          :body (org-wiki-memory--section "Body")))))
         (t (signal 'org-wiki-error '(:invalid_record))))))))

(defun org-wiki-memory--section (name)
  "Read text from the managed section NAME."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (concat "^\\* " name "$") nil t)
      (forward-line)
      (let ((start (point)))
        (if (re-search-forward "^\\* " nil t) (goto-char (match-beginning 0))
          (goto-char (point-max)))
        (string-trim-right (replace-regexp-in-string
                            "^: " "" (buffer-substring-no-properties start (point))))))))

(defun org-wiki-memory--script-file (file root path)
  "Resolve PATH under ROOT for the project memory at FILE, or return nil."
  (when (and (stringp root) (file-name-absolute-p root) (not (file-remote-p root))
             (file-directory-p root) (equal root (file-truename root))
             (stringp path) (not (file-name-absolute-p path))
             (not (string-match-p "[[:cntrl:]]" path)))
    (let* ((default-directory (file-name-as-directory root))
           (script (expand-file-name path root))
           (project (if (not (file-exists-p (expand-file-name ".git" root))) root
                      (with-temp-buffer
                        (when (zerop (process-file "git" nil t nil "rev-parse"
                                                   "--path-format=absolute" "--git-common-dir"))
                          (file-truename (string-trim-right (buffer-string))))))))
      (when (and project
                 (equal (directory-file-name (file-name-directory file))
                        (org-wiki-memory--directory (secure-hash 'sha256 project)))
                 (equal script (file-truename script)) (file-in-directory-p script root)
                 (equal path (file-relative-name script root))
                 (file-regular-p script) (file-readable-p script))
        script))))

(defun org-wiki-memory--script-text (file root path)
  "Read the script referenced by memory FILE with ROOT and PATH."
  (when-let* ((script (org-wiki-memory--script-file file root path)))
    (with-temp-buffer (insert-file-contents script) (buffer-string))))

(defun org-wiki-memory--properties (file scope args old workspace)
  "Build properties for FILE in SCOPE from ARGS, OLD and WORKSPACE."
  (let ((kind (alist-get 'kind args (or (plist-get old :kind) "Memory")))
        (path (alist-get 'script_path args (plist-get old :script_path)))
        (root (plist-get old :script_root)))
    (when (eq kind :null) (setq kind "Memory"))
    (unless (member kind org-wiki-memory-kinds)
      (signal 'org-wiki-error '(:invalid_kind)))
    (when (and (assq 'script_path args) (not (eq path :null)))
      (org-wiki-memory--field args 'script_path)
      (unless (and (equal scope "project") (stringp workspace)
                   (file-name-absolute-p workspace) (not (file-remote-p workspace)))
        (signal 'org-wiki-error '(:invalid_script)))
      (setq root (directory-file-name
                  (file-truename (or (locate-dominating-file workspace ".git") workspace))))
      (unless (and (not (string-match-p "[[:cntrl:]]" root))
                   (org-wiki-memory--script-file file root path))
        (signal 'org-wiki-error '(:invalid_script))))
    (concat "\n:WIKI_KIND: " kind
            (when (stringp path) (concat "\n:SCRIPT_PATH: " path "\n:SCRIPT_ROOT: " root)))))

(defun org-wiki-memory--mask-links (text explicit)
  "Mask links in TEXT for name matching and record ID offsets in EXPLICIT."
  (with-temp-buffer
    (let ((start 0))
      (while (string-match org-link-any-re text start)
        (let* ((begin (match-beginning 0))
               (end (match-end 0))
               (raw (match-string 0 text))
               (path (cond ((string-match org-link-bracket-re raw)
                            (org-link-unescape (match-string 1 raw)))
                           ((string-prefix-p "<" raw) (substring raw 1 -1))
                           (t raw))))
          (when (string-prefix-p "id:" path)
            (let ((id (substring path 3)))
              (unless (gethash id explicit) (puthash id begin explicit))))
          (insert (substring text start begin) (make-string (- end begin) ?\s))
          (setq start end)))
      (insert (substring text start))
      (buffer-string))))

(defun org-wiki-memory--indexed-title ()
  "Return the Org-roam title of the file or heading at point."
  (if (org-at-heading-p) (org-link-display-format (org-get-heading t t t t))
    (org-roam-db--file-title)))

(defun org-wiki-memory--link-target (id file managed visible)
  "Verify indexed ID in FILE on disk, limiting MANAGED memories to VISIBLE dirs."
  (when (and (not (file-remote-p file)) (file-regular-p file))
    (let ((path (file-truename file)))
      (when (and (org-roam-file-p path)
                 (or (not (string-prefix-p managed path))
                     (member (file-name-directory path) visible)))
        (with-temp-buffer
          (insert-file-contents path)
          (setq buffer-file-name path)
          (delay-mode-hooks (org-mode))
          (when-let* ((pos (org-find-entry-with-id id)))
            (goto-char pos)
            (when (and (org-roam-db-node-p)
                       (or (member (file-name-directory path) visible)
                           (not (org-entry-get (point-min) "MEMORY_SCOPE"))))
              (let ((names (cons (org-wiki-memory--indexed-title)
                                 (ignore-errors (split-string-and-unquote
                                                 (or (org-entry-get nil "ROAM_ALIASES") ""))))))
                ;; A legacy file ID can refer to its first wiki heading.
                (unless (or (org-at-heading-p) (org-wiki--file-node-p))
                  (when-let* ((heading (car (org-wiki--node-positions))))
                    (goto-char heading)))
                (when-let* ((canonical (org-entry-get nil "ID"))
                            ((or (equal canonical id)
                                 (and (org-roam-db-node-p)
                                      (org-roam-db-query
                                       [:select id :from nodes :where (= id $s1) :and (= file $s2)]
                                       canonical file)))))
                  (list :id canonical :title (org-wiki-memory--indexed-title)
                        :names (mapcar #'downcase names)))))))))))

(defun org-wiki-memory--inside-name-p (text offset)
  "Return non-nil if OFFSET falls inside an ASCII identifier in TEXT."
  (and (< 0 offset (length text))
       (string-match-p "[a-zA-Z0-9_][a-zA-Z0-9_]"
                       (substring text (1- offset) (1+ offset)))))

(defun org-wiki-memory--link-matches (file self text rows)
  "Find unique mentions in TEXT among indexed ROWS for memory FILE and SELF."
  (let* ((dir (file-name-directory file))
         (managed (file-name-directory (directory-file-name dir)))
         (visible (list dir (expand-file-name "personal/" managed)))
         (explicit (make-hash-table :test #'equal))
         (plain (org-wiki-memory--mask-links text explicit))
         (folded (downcase plain))
         (verified (make-hash-table :test #'equal))
         (owners (make-hash-table :test #'equal))
         id-hits name-hits)
    (pcase-dolist (`(,id ,path ,title ,alias) rows)
      (let ((offset (gethash id explicit))
            (names (cl-loop for raw in (delq nil (list title alias))
                            for name = (downcase raw)
                            when (and (> (length name) 1) (string-search name folded))
                            collect name)))
        (when (and (not (equal id self)) (or offset names))
          ;; Open only textual hits and reuse targets matched by several aliases.
          (let ((target (with-memoization (gethash id verified)
                          (condition-case nil
                              (org-wiki-memory--link-target id path managed visible)
                            (file-error nil)))))
            (when (and target (not (equal (plist-get target :id) self)))
              (when offset (cl-pushnew (cons offset target) id-hits :test #'equal))
              (dolist (name names)
                (when (member name (plist-get target :names))
                  (cl-pushnew target (gethash name owners)
                              :key (lambda (node) (plist-get node :id)) :test #'equal))))))))
    (when (> (hash-table-count owners) 0)
      (let ((pattern (regexp-opt (hash-table-keys owners)))
            (case-fold-search t)
            (start 0))
        (while (string-match pattern plain start)
          (let* ((begin (match-beginning 0)) (end (match-end 0))
                 (matches (gethash (downcase (match-string 0 plain)) owners)))
            (if (or (org-wiki-memory--inside-name-p plain begin)
                    (org-wiki-memory--inside-name-p plain end))
                (setq start (1+ begin))
              (setq start end)
              (when (and matches (not (cdr matches)))
                (push (cons begin (car matches)) name-hits)))))))
    (seq-take (cl-delete-duplicates
               (nconc (cl-sort id-hits #'< :key #'car) (nreverse name-hits))
               :key (lambda (hit) (plist-get (cdr hit) :id)) :test #'equal :from-end t)
              org-wiki-memory-max-links)))

(defun org-wiki-memory--relation-item (hit text)
  "Render HIT as a real Org link with its original context from TEXT."
  (let* ((pos (car hit))
         (node (cdr hit))
         (link (org-link-make-string (concat "id:" (plist-get node :id))
                                     (plist-get node :title)))
         (before (substring text (max 0 (- pos 120)) pos))
         (after (substring text pos (min (length text) (+ pos 160))))
         (start (string-match "[^\n。！？.!?]*\\'" before))
         (end (string-match "[\n。！？.!?]" after)))
    (concat "- " link "\n  : "
            (string-trim (concat (substring before start)
                                 (substring after 0 (and end (1+ end))))) "\n")))

(defun org-wiki-memory--relations (file id text)
  "Build the managed Relations section for memory FILE with ID and TEXT."
  (when (> org-wiki-memory-max-links 0)
    (let ((items
           (condition-case err
               (when (and (require 'org-roam nil t) (org-wiki--roam-db-ready-p))
                 (let* ((rows (org-roam-db-query
                               [:select [nodes:id nodes:file nodes:title aliases:alias]
                                        :from nodes :left-join aliases :on (= aliases:node-id nodes:id)]))
                        (hits (org-wiki-memory--link-matches file id text rows)))
                   (mapconcat (lambda (hit) (org-wiki-memory--relation-item hit text)) hits "")))
             (error (message "Org memory link lookup: %s" (error-message-string err)) nil))))
      ;; An unavailable index must not erase links already saved on disk.
      (unless (or items (not (file-exists-p file)))
        (setq items (with-temp-buffer
                      (insert-file-contents file)
                      (org-wiki-memory--section "Relations"))))
      (when (and items (not (string-empty-p items)))
        (concat "\n* Relations\n" (string-trim-right items) "\n")))))

(defun org-wiki-memory--draft (path scope args source request create-key old workspace)
  "Build (ID FILE TEXT) for a memory in SCOPE from ARGS and SOURCE.
PATH is the existing file for OLD or the creation lock path in its target
directory.  REQUEST identifies this operation and CREATE-KEY its original
creation.  Resolve script references relative to WORKSPACE."
  (let ((category (org-wiki-memory--field args 'category))
        (title (org-wiki-memory--field args 'title))
        (summary (org-wiki-memory--field args 'summary))
        (body (org-wiki-memory--field args 'body t)))
    (unless (member category '("preference" "decision" "lesson" "fact"))
      (signal 'org-wiki-error '(:invalid_category)))
    (with-temp-buffer
      (insert ":PROPERTIES:\n:MEMORY_CREATE_KEY: " create-key
              (if old (concat "\n:ID: " (plist-get old :id)) "")
              (org-wiki-memory--properties path scope args old workspace)
              "\n:MEMORY_SCOPE: " scope "\n:CATEGORY: " category
              "\n:MEMORY_SOURCE: " (or (plist-get old :source) source)
              "\n:UPDATED_BY: " source "\n:LAST_REQUEST: " request "\n:UPDATED: "
              (format-time-string "%FT%TZ" nil t) "\n:END:\n#+title: " title
              "\n\n* Summary\n: " summary "\n\n* Body\n"
              (replace-regexp-in-string "^" ": " body) "\n")
      (delay-mode-hooks (org-mode))
      (goto-char (point-min))
      (let* ((id (or (plist-get old :id)
                     ;; Publish the final path only after atomic replacement.
                     (let ((org-id-overriding-file-name path) (org-id-track-globally nil))
                       (org-id-get-create))))
             (file (if old path
                     (expand-file-name
                      (concat (format-time-string "%Y%m%dT%H%M%SZ" (current-time) t) "-"
                              (substring request 0 12) "-" (org-wiki-memory--id-suffix id) ".org")
                      (file-name-directory path)))))
        (goto-char (point-max))
        (when-let* ((links (org-wiki-memory--relations file id (string-join (list title summary body) "\n"))))
          (insert links))
        (list id file (buffer-string))))))

(defun org-wiki-memory--search-result (row)
  "Return the public search fields from memory record ROW."
  (append (list :kind (plist-get row :kind))
          (when (plist-get row :script_path) (list :script_path (plist-get row :script_path)))
          (list :category (plist-get row :category) :id (plist-get row :id) :revision (plist-get row :revision)
                :scope (plist-get row :scope) :title (plist-get row :title)
                :summary (plist-get row :summary))))

(defun org-wiki-memory--matches-p (row filters)
  "Return non-nil when ROW is a memory matching FILTERS."
  (and (plist-get row :id)
       (or (not (alist-get 'kind filters)) (equal (alist-get 'kind filters) (plist-get row :kind)))
       (or (not (alist-get 'category filters)) (equal (alist-get 'category filters) (plist-get row :category)))))

(defun org-wiki-memory--qmd-result (dirs node filters)
  "Return a verified memory result for qmd NODE in DIRS matching FILTERS."
  (let ((file (plist-get node :file)))
    (when (member (directory-file-name (file-name-directory file)) dirs)
      (let ((row (org-wiki-memory--record file)))
        (when (and (org-wiki-memory--matches-p row filters)
                   (equal (plist-get row :id) (plist-get node :id))
                   (org-wiki-qmd--validate-node node))
          (org-wiki-memory--search-result row))))))

(defun org-wiki-memory--text-search (dirs query filters)
  "Rank records under DIRS by literal QUERY and FILTERS."
  (let* ((query (downcase query))
         (terms (split-string query "[^[:alnum:]]+" t))
         hits)
    (with-temp-buffer
      (insert query)
      (goto-char (point-min))
      (while (re-search-forward "\\cc\\cc" nil t)
        (push (match-string 0) terms)
        (backward-char)))
    (setq terms (delete-dups terms))
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (file (directory-files dir t "\\.org\\'"))
          (let ((row (org-wiki-memory--record file)))
            (when (org-wiki-memory--matches-p row filters)
              (let* ((excerpt (downcase (concat (plist-get row :title) " " (plist-get row :summary))))
                     (body (downcase (concat (plist-get row :body) "\n"
                                             (when (and terms (plist-get row :script_path))
                                               (org-wiki-memory--script-text
                                                file (plist-get row :script_root) (plist-get row :script_path))))))
                     (score (cl-loop for term in terms for pattern = (regexp-quote term)
                                     sum (+ (if (string-match-p pattern excerpt) 3 0)
                                            (if (string-match-p pattern body) 1 0)))))
                (when (or (string-empty-p query) (> score 0))
                  (push (cons score (org-wiki-memory--search-result row)) hits))))))))
    (mapcar #'cdr (cl-stable-sort (nreverse hits) #'> :key #'car))))

(defconst org-wiki-memory--situations
  `(("understand" "道" ,(rx (or "通用规律" "一般规律" "为什么" "为何" "背后的原理" "什么原理"
                                (seq word-start (or "why" "explain" "underlying principle") word-end))))
    ("design" "法" ,(rx (or "设计准则" "设计原则" "怎么设计" "如何设计" "架构设计" "如何取舍" "如何选型"
                            (seq word-start (or "design" "architecture" "tradeoffs" "trade-offs") word-end))))
    ("implement" "术" ,(rx (or "具体实施" "具体实现" "如何实现" "怎么实现" "如何运行" "怎么运行" "怎么复现"
                               "如何复现" "验证脚本" "运行命令" "怎么写"
                               (seq word-start (or "implement" "implementation" "reproduce" "run the script")
                                    word-end)))))
  "Search situations, their summary marks, and cues for automatic recall.")

(defun org-wiki-memory--preferred-kind (args query)
  "Choose a summary mark from ARGS or an unambiguous cue in QUERY."
  (let* ((situation (alist-get 'situation args))
         (explicit (assoc situation org-wiki-memory--situations)))
    (when (and situation (not explicit))
      (signal 'org-wiki-error '(:invalid_situation)))
    (unless (assq 'kind args)
      (if explicit (cadr explicit)
        (let* ((case-fold-search t)
               (matches (seq-filter (lambda (rule) (string-match-p (nth 2 rule) query))
                                    org-wiki-memory--situations)))
          (when (= 1 (length matches)) (cadar matches)))))))

(defun org-wiki-memory--search (dirs args)
  "Search saved records in DIRS using query and limit in ARGS."
  (let ((query (if (or (assq 'query args) (not (or (assq 'kind args) (assq 'category args))))
                   (org-wiki-memory--field args 'query t) ""))
        (limit (or (alist-get 'limit args) 5)))
    (unless (and (integerp limit) (<= 1 limit 50))
      (signal 'org-wiki-error '(:invalid_limit)))
    (let* ((kind (org-wiki-memory--preferred-kind args query))
           ;; Keep a wider set of topical candidates before selecting summaries.
           (candidates (or (org-wiki--try-qmd
                            query (if kind (max 20 (* 4 limit)) limit)
                            (lambda (node) (org-wiki-memory--qmd-result dirs node args)))
                           (org-wiki-memory--text-search dirs query args)))
           (preferred (and kind (seq-filter (lambda (row) (equal kind (plist-get row :kind)))
                                            candidates))))
      (vconcat (seq-take (or preferred candidates) limit)))))

(defun org-wiki-memory--write (file text &optional new)
  "Write TEXT atomically under the lock for FILE, requiring a fresh path if NEW."
  (let ((temp (make-temp-file (expand-file-name ".write-" (file-name-directory file))))
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn (write-region text nil temp nil 'silent)
               (condition-case nil
                   (rename-file temp file (not new))
                 (file-already-exists (signal 'org-wiki-error '(:id_conflict)))))
      (when (file-exists-p temp) (delete-file temp)))))

(defun org-wiki-memory--with-lock (file action)
  "Call ACTION with the lock for FILE held."
  (make-directory (file-name-directory file) t)
  (when (file-locked-p file) (signal 'org-wiki-error '(:busy)))
  (let ((create-lockfiles t))
    (cl-letf (((symbol-function 'ask-user-about-lock)
               (lambda (&rest _) (signal 'org-wiki-error '(:busy))))
              ((symbol-function 'ask-user-about-supersession-threat)
               (lambda (&rest _) (signal 'org-wiki-error '(:revision_conflict)))))
      (lock-file file))
    (unwind-protect (funcall action)
      (unlock-file file))))

(defun org-wiki-memory--index-file (file)
  "Refresh backlinks for FILE after an atomic write or a replay."
  (condition-case err
      (when (and (require 'org-roam nil t) (org-wiki--roam-db-ready-p)
                 (org-roam-file-p file))
        (org-roam-db-update-file file))
    (error (message "Org memory backlink index: %s" (error-message-string err)))))

(defun org-wiki-memory--stored-key (file)
  "Read the creation key in FILE's property drawer or tombstone."
  (when (file-symlink-p file) (signal 'org-wiki-error '(:unsafe_path)))
  (with-temp-buffer
    ;; Creation scans only the header of each record in this scope.
    (insert-file-contents file nil 0 1024)
    (cond
     ((looking-at org-wiki-memory--forgotten) (match-string 2))
     ((looking-at-p ":PROPERTIES:$")
      (unless (save-excursion (re-search-forward "^:END:$" nil t))
        (erase-buffer)
        (insert-file-contents file))
      (when-let* ((end (save-excursion (re-search-forward "^:END:$" nil t)))
                  ((re-search-forward "^:MEMORY_CREATE_KEY:[ \t]+\\([a-f0-9]\\{64\\}\\)[ \t]*$" end t)))
        (match-string 1))))))

(defun org-wiki-memory--mutate (file id scope op args source request workspace &optional draft)
  "Apply OP with ARGS to FILE in SCOPE, from SOURCE, REQUEST and WORKSPACE.
ID is the requested Org ID, or nil when replaying a creation by key.
DRAFT contains the complete Org text for a new record."
  (org-wiki-memory--with-lock
   file
   (lambda ()
     (let* ((buffer (find-buffer-visiting file))
            (old (org-wiki-memory--record file))
            (forgotten (plist-get old :forgotten)))
       (when (and buffer (buffer-modified-p buffer))
         (signal 'org-wiki-error '(:unsaved_edits)))
       (let ((text
              (cond
               (draft (when old (signal 'org-wiki-error '(:id_conflict))) draft)
               ((null old) (signal 'org-wiki-error '(:unknown_id)))
               (forgotten
                (unless (and (equal op "forget") (equal forgotten request))
                  (signal 'org-wiki-error '(:unknown_id))))
               ((and id (not (equal id (plist-get old :id))))
                (signal 'org-wiki-error '(:unknown_id)))
               ((equal request (plist-get old :request)) nil)
               ((equal op "remember") (signal 'org-wiki-error '(:request_conflict)))
               ((not (equal (plist-get old :revision) (alist-get 'expected_revision args)))
                (signal 'org-wiki-error '(:revision_conflict)))
               (t
                (let ((key (or (org-wiki-memory--stored-key file)
                               (and (string-match "\\`mem-\\([a-f0-9]\\{64\\}\\)\\'" id)
                                    (match-string 1 id))
                               (signal 'org-wiki-error '(:invalid_record)))))
                  (if (equal op "forget") (concat "Forgotten " request " " key "\n")
                    (nth 2 (org-wiki-memory--draft file scope args source request key old workspace))))))))
         (when text
           (org-wiki-memory--write file text (and draft t))
           (when buffer
             (with-current-buffer buffer
               (let ((enable-local-variables nil) (enable-local-eval nil))
                 (revert-buffer t t))))
           (unless (equal op "forget") (setq old (org-wiki-memory--record file)))))
       (unless (equal op "forget")
         (org-id-add-location (plist-get old :id) file))
       ;; Atomic replacement bypasses the normal after-save indexing hook.
       (org-wiki-memory--index-file file)
       (if (equal op "forget") (list :id id :forgotten t) old)))))

(defun org-wiki-memory--find-file (dir id)
  "Find the filename for ID in DIR, including the legacy bare ID format."
  (let* ((name (concat (org-wiki-memory--id-suffix id) ".org"))
         (legacy (expand-file-name (concat "./" name) dir)))
    (if (or (file-exists-p legacy) (file-symlink-p legacy))
        legacy
      (when (file-directory-p dir)
        (car (directory-files
              dir t (concat "\\`" org-wiki-memory--filename-prefix (regexp-quote name) "\\'")))))))

(defun org-wiki-memory--created-file (dir key)
  "Locate the record or tombstone for creation KEY in DIR."
  (let* ((legacy (org-wiki-memory--find-file dir (concat "mem-" key)))
         (stored (and legacy (org-wiki-memory--stored-key legacy))))
    (or (and legacy (or (null stored) (equal stored key)) legacy)
        (seq-find (lambda (file)
                    (and (not (file-symlink-p file)) (file-regular-p file)
                         (equal key (org-wiki-memory--stored-key file))))
                  (directory-files dir t "\\.org\\'" t)))))

(defun org-wiki-memory--occupied-id-p (managed id)
  "Check managed memory filenames and indexed Org nodes for ID under the ID lock.
MANAGED is the parent of all memory scopes."
  (or (seq-some (lambda (dir)
                  (and (not (file-symlink-p dir)) (file-directory-p dir)
                       (org-wiki-memory--find-file dir id)))
                (directory-files managed t "\\`\\(?:personal\\|[a-f0-9]\\{64\\}\\)\\'"))
      (seq-some (lambda (file)
                  (and file (not (file-remote-p file)) (file-regular-p file)
                       (org-id-find-id-in-file id file)))
                (list (org-id-find-id-file id)
                      (when (and (require 'org-roam nil t) (org-wiki--roam-db-ready-p))
                        (caar (ignore-errors
                                (org-roam-db-query [:select file :from nodes :where (= id $s1)] id))))))))

(defun org-wiki-memory--remember (dir key scope args source request workspace)
  "Save ARGS in DIR with creation KEY and SCOPE.
SOURCE, REQUEST and WORKSPACE describe the current tool call."
  (let ((lock (expand-file-name (concat ".mem-" key) dir))
        (managed (file-name-directory (directory-file-name dir))))
    (org-wiki-memory--with-lock
     lock
     (lambda ()
       (if-let* ((file (org-wiki-memory--created-file dir key)))
           (org-wiki-memory--mutate file nil scope "remember" args source request workspace)
         (pcase-let ((`(,id ,file ,text) (org-wiki-memory--draft lock scope args source request key nil workspace)))
           ;; Different creation keys (even in different projects) may receive
           ;; the same Org ID, e.g. with a seconds-only timestamp configuration.
           (org-wiki-memory--with-lock
            (expand-file-name (concat ".id-" (secure-hash 'sha256 id)) managed)
            (lambda ()
              (when (org-wiki-memory--occupied-id-p managed id)
                (signal 'org-wiki-error '(:id_conflict)))
              (org-wiki-memory--mutate file id scope "remember" args source request workspace text)))))))))

(defun org-wiki-memory--call (op ctx args)
  "Run OP with host context CTX and model arguments ARGS."
  (let* ((project (secure-hash 'sha256 (org-wiki-memory--field ctx 'project)))
         (dirs (mapcar #'org-wiki-memory--directory (list project "personal"))))
    (if (equal op "search") (org-wiki-memory--search dirs args)
      (unless (member op '("read" "remember" "update" "forget"))
        (signal 'org-wiki-error '(:invalid_operation)))
      (let* ((create (equal op "remember"))
             (scope (or (alist-get 'scope args) "project"))
             (key (unless (equal op "read") (org-wiki-memory--field ctx 'request)))
             (source (unless (equal op "read")
                       (concat (org-wiki-memory--field ctx 'host) "/" (org-wiki-memory--field ctx 'session))))
             (request (when key (secure-hash 'sha256 (prin1-to-string (list op source key args))))))
        (unless (member scope '("project" "personal"))
          (signal 'org-wiki-error '(:invalid_record)))
        (if create
            (org-wiki-memory--remember (if (equal scope "personal") (cadr dirs) (car dirs))
                                       (secure-hash 'sha256 (prin1-to-string (list project scope source key)))
                                       scope args source request (alist-get 'workspace ctx))
          (let* ((id (alist-get 'id args))
                 (file (or (org-wiki-memory--find-file (car dirs) id)
                           (org-wiki-memory--find-file (cadr dirs) id)
                           (signal 'org-wiki-error '(:unknown_id)))))
            (if (equal op "read")
                (let ((row (org-wiki-memory--record file)))
                  (unless (equal id (plist-get row :id)) (signal 'org-wiki-error '(:unknown_id)))
                  (if (and (eq (alist-get 'include_script args) t) (plist-get row :script_path))
                      (plist-put row :script_content
                                 (or (org-wiki-memory--script-text file (plist-get row :script_root)
                                                                   (plist-get row :script_path))
                                     (signal 'org-wiki-error '(:script_unavailable))))
                    row))
              (org-wiki-memory--mutate
               file id (if (equal (directory-file-name (file-name-directory file)) (cadr dirs))
                           "personal" "project")
               op args source request (alist-get 'workspace ctx)))))))))

(defun org-wiki-memory--dispatch (operation context arguments)
  "Dispatch OPERATION with JSON host CONTEXT and JSON ARGUMENTS.

MCP Parameters:
  operation - memory operation name.
  context - JSON host context with project and session identity.
  arguments - JSON operation arguments."
  (org-wiki-mcp--with-error-handling
    (json-encode (org-wiki-memory--call operation
                                        (json-parse-string context :object-type 'alist)
                                        (json-parse-string arguments :object-type 'alist)))))

(defvar org-wiki-memory--enabled nil)

;;;###autoload
(defun org-wiki-memory-enable ()
  "Register the local agent memory endpoint once in this Emacs."
  (interactive)
  (unless mcp-server-lib--running (mcp-server-lib-start))
  (unless org-wiki-memory--enabled
    (mcp-server-lib-register-server
     :id "org-wiki-memory"
     :tools '((org-wiki-memory--dispatch :id "org_memory_dispatch"
                                         :description "Scoped calls from local memory adapters.")))
    (setq org-wiki-memory--enabled t)))

(provide 'org-wiki-memory)
;;; org-wiki-memory.el ends here
