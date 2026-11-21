;;; org-wiki-memory.el --- Project and personal agent memory -*- lexical-binding: t; -*-

;;; Commentary:

;; Durable, scoped Org records for local agent hosts.  The host supplies
;; the canonical workspace and session.  No index is needed to read a write.

;;; Code:

(require 'org-wiki-mcp)
(require 'mcp-server-lib-commands)
(require 'seq)
(require 'subr-x)

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
         ((looking-at "Forgotten \\([[:xdigit:]]+\\)\n\\'")
          (list :forgotten (match-string 1)))
         ((looking-at ":PROPERTIES:$")
          (delay-mode-hooks (org-mode))
          (let ((id (org-entry-get nil "ID")))
            (unless (and (equal id (file-name-base file))
                         (equal (org-entry-get nil "WIKI_KIND") "Memory"))
              (signal 'org-wiki-error '(:invalid_record)))
            (list :id id :revision revision :scope (org-entry-get nil "MEMORY_SCOPE")
                  :category (org-entry-get nil "CATEGORY")
                  :source (org-entry-get nil "MEMORY_SOURCE")
                  :updated (org-entry-get nil "UPDATED")
                  :updated_by (org-entry-get nil "UPDATED_BY")
                  :request (org-entry-get nil "LAST_REQUEST")
                  :title (org-wiki--file-title file)
                  :summary (org-wiki-memory--section "Summary")
                  :body (org-wiki-memory--section "Body"))))
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

(defun org-wiki-memory--render (id scope args source editor request)
  "Render ID, SCOPE, ARGS, SOURCE, EDITOR and REQUEST as an Org file."
  (let ((category (org-wiki-memory--field args 'category)))
    (unless (member category '("preference" "decision" "lesson" "fact"))
      (signal 'org-wiki-error '(:invalid_category)))
    (concat ":PROPERTIES:\n:ID: " id "\n:WIKI_KIND: Memory\n:MEMORY_SCOPE: " scope
            "\n:CATEGORY: " category "\n:MEMORY_SOURCE: " source
            "\n:UPDATED_BY: " editor "\n:LAST_REQUEST: " request "\n:UPDATED: "
            (format-time-string "%FT%TZ" nil t) "\n:END:\n#+title: "
            (org-wiki-memory--field args 'title)
            "\n\n* Summary\n: " (org-wiki-memory--field args 'summary)
            "\n\n* Body\n" (replace-regexp-in-string
                            "^" ": " (org-wiki-memory--field args 'body t))
            "\n")))

(defun org-wiki-memory--search (dirs args)
  "Rank saved records under DIRS using query and limit in ARGS."
  (let* ((query (downcase (org-wiki-memory--field args 'query t)))
         (terms (split-string query "[^[:alnum:]]+" t))
         (limit (or (alist-get 'limit args) 5))
         hits)
    (unless (and (integerp limit) (<= 1 limit 50))
      (signal 'org-wiki-error '(:invalid_limit)))
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
            (when (plist-get row :id)
              (let* ((excerpt (downcase (concat (plist-get row :title) " " (plist-get row :summary))))
                     (body (downcase (or (plist-get row :body) "")))
                     (score (cl-loop for term in terms for pattern = (regexp-quote term)
                                     sum (+ (if (string-match-p pattern excerpt) 3 0)
                                            (if (string-match-p pattern body) 1 0)))))
                (when (> score 0)
                  (push (cons score (list :id (plist-get row :id)
                                          :revision (plist-get row :revision)
                                          :scope (plist-get row :scope)
                                          :title (plist-get row :title)
                                          :summary (plist-get row :summary))) hits))))))))
    (vconcat (mapcar #'cdr (seq-take (cl-stable-sort (nreverse hits) #'> :key #'car) limit)))))

(defun org-wiki-memory--write (file text)
  "Replace FILE atomically with TEXT while the caller owns its lock."
  (let ((temp (make-temp-file (expand-file-name ".write-" (file-name-directory file))))
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn (write-region text nil temp nil 'silent)
               (rename-file temp file t))
      (when (file-exists-p temp) (delete-file temp)))))

(defun org-wiki-memory--mutate (file id scope op args source request)
  "Apply OP with ARGS to FILE for ID and SCOPE, recording SOURCE and REQUEST."
  (make-directory (file-name-directory file) t)
  (when (file-locked-p file) (signal 'org-wiki-error '(:busy)))
  (let ((create-lockfiles t))
    (cl-letf (((symbol-function 'ask-user-about-lock)
               (lambda (&rest _) (signal 'org-wiki-error '(:busy))))
              ((symbol-function 'ask-user-about-supersession-threat)
               (lambda (&rest _) (signal 'org-wiki-error '(:revision_conflict)))))
      (lock-file file)))
  (unwind-protect
      (let* ((buffer (find-buffer-visiting file))
             (old (org-wiki-memory--record file))
             (forgotten (plist-get old :forgotten)))
        (when (and buffer (buffer-modified-p buffer))
          (signal 'org-wiki-error '(:unsaved_edits)))
        (cond
         ((and (equal op "forget") (equal forgotten request)) (list :id id :forgotten t))
         (forgotten (signal 'org-wiki-error '(:unknown_id)))
         ((equal (plist-get old :request) request) old)
         ((and old (equal op "remember")) (signal 'org-wiki-error '(:request_conflict)))
         (t
          (unless (equal op "remember")
            (unless old (signal 'org-wiki-error '(:unknown_id)))
            (unless (equal (plist-get old :revision) (alist-get 'expected_revision args))
              (signal 'org-wiki-error '(:revision_conflict))))
          (org-wiki-memory--write
           file (if (equal op "forget") (concat "Forgotten " request "\n")
                  (org-wiki-memory--render id scope args (or (plist-get old :source) source) source request)))
          (when buffer
            (with-current-buffer buffer
              (let ((enable-local-variables nil) (enable-local-eval nil))
                (revert-buffer t t))))
          (if (equal op "forget") (list :id id :forgotten t)
            (org-id-add-location id file)
            (org-wiki-memory--record file)))))
    (let ((create-lockfiles t)) (unlock-file file))))

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
             (id (if create (concat "mem-" (secure-hash 'sha256 (prin1-to-string (list project scope source key))))
                   (org-wiki-memory--field args 'id))))
        (unless (and (member scope '("project" "personal"))
                     (string-match-p "\\`mem-[a-f0-9]\\{64\\}\\'" id))
          (signal 'org-wiki-error '(:invalid_record)))
        (let* ((files (mapcar (lambda (dir) (expand-file-name (concat id ".org") dir)) dirs))
               (file (if create (if (equal scope "personal") (cadr files) (car files))
                       (or (seq-find #'file-exists-p files) (signal 'org-wiki-error '(:unknown_id))))))
          (if (equal op "read")
              (let ((row (org-wiki-memory--record file)))
                (if (plist-get row :id) row (signal 'org-wiki-error '(:unknown_id))))
            (org-wiki-memory--mutate
             file id (if (equal file (cadr files)) "personal" "project") op args source
             (secure-hash 'sha256 (prin1-to-string (list op source key args))))))))))

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
