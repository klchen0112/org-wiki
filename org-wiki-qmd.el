;;; org-wiki-qmd.el --- Optional qmd search and derived indexes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley
;; Author: John Wiegley <johnw@gnu.org>
;; Version: 0.2.0
;; Keywords: outlines, tools
;; URL: https://github.com/jwiegley/dot-emacs

;;; Commentary:

;; Node-grained Markdown caches bridge qmd to canonical Org IDs.
;; Searches never maintain indexes.  Explicit maintenance uses an owned
;; config/database, a cross-process lock, and a durable commit marker.
;; Knowledge-base files are never written or exported through Org hooks.

;;; Code:

(require 'org-wiki)
(require 'json)
(require 'url-util)

(declare-function org-roam-db-query "org-roam-db")
(declare-function org-wiki-memory--script-file "org-wiki-memory" (file root path))

(defgroup org-wiki-qmd nil
  "Optional local qmd search."
  :group 'org-wiki)

(defcustom org-wiki-qmd-program "qmd"
  "Executable for the qmd CLI."
  :type 'file :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-index-name nil
  "Dedicated index name, or nil to derive one from the knowledge base.
Configuration and database paths are isolated even for explicit names."
  :type '(choice (const nil) string) :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-collection nil
  "Dedicated collection name; nil means qmd is not configured."
  :type '(choice (const nil) string) :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-cache-directory nil
  "Owned cache directory, or nil for a knowledge-base-specific default.
Do not share an explicit directory between different knowledge bases."
  :type '(choice (const nil) directory) :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-discovery-scope 'root-and-roam
  "Sources required for a complete sync.
Use root-only explicitly when there is no org-roam database."
  :type '(choice (const root-and-roam) (const root-only))
  :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-search-mode 'search
  "CLI search mode.  Vector modes require explicit embedding first."
  :type '(choice (const search) (const vsearch) (const query))
  :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-search-timeout 10
  "Total seconds allowed for a search, including additional candidates."
  :type 'number :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-maintenance-timeout 1800
  "Seconds allowed for each explicit maintenance process."
  :type 'number :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-output-limit (* 4 1024 1024)
  "Maximum combined stdout and stderr bytes per qmd process."
  :type 'integer :group 'org-wiki-qmd)

(defcustom org-wiki-qmd-models nil
  "Plist of predownloaded local GGUF paths for vector searches.
Keys are :embed, :generate and :rerank.  Vsearch needs :embed and
:generate for query expansion; query also needs :rerank.
Embedding maintenance only needs :embed.  Paths are pinned in the state so
queries never download models or silently change embedding models."
  :type 'plist :group 'org-wiki-qmd)

(defconst org-wiki-qmd--version "2.8.3"
  "Baseline CLI version used by packaged builds.")

(defconst org-wiki-qmd--versions (delete-dups (list org-wiki-qmd--version "2.9.0"))
  "Versions verified by the qmd CLI integration checks.")

(defvar org-wiki-qmd--lock-token nil
  "Token for the current maintenance lock, dynamically bound.")
(defvar org-wiki-qmd--diagnostics nil
  "Node-level diagnostics from the latest sync.")

(defun org-wiki-qmd--identity ()
  "Return the stable identity of the current knowledge base."
  (secure-hash 'sha256
               (directory-file-name (file-truename (expand-file-name org-wiki-root)))))

(defun org-wiki-qmd--directory ()
  "Return the owned cache directory without creating it."
  (file-name-as-directory
   (expand-file-name
    (or org-wiki-qmd-cache-directory
        (expand-file-name (concat "org-wiki/qmd/" (org-wiki-qmd--identity))
                          user-emacs-directory)))))

(defun org-wiki-qmd--path (name)
  "Return the owned path for NAME."
  (expand-file-name name (org-wiki-qmd--directory)))

(defun org-wiki-qmd--index ()
  "Return the dedicated index name."
  (or org-wiki-qmd-index-name
      (concat "org-wiki-" (substring (org-wiki-qmd--identity) 0 16))))

(defun org-wiki-qmd--validate-config ()
  "Reject missing or unsafe qmd configuration."
  (dolist (name (list (org-wiki-qmd--index) org-wiki-qmd-collection))
    (unless (and (stringp name)
                 (string-match-p "\\`[a-zA-Z0-9][a-zA-Z0-9_-]*\\'" name))
      (user-error "Configure a qmd index and collection using letters, digits, - or _")))
  (unless (memq org-wiki-qmd-discovery-scope '(root-and-roam root-only))
    (user-error "Invalid qmd discovery scope"))
  (unless (memq org-wiki-qmd-search-mode '(search vsearch query))
    (user-error "Invalid qmd search mode"))
  (when (file-remote-p org-wiki-root)
    (user-error "QMD requires a local wiki root")))

(defun org-wiki-qmd--read (name)
  "Read owned JSON file NAME, returning nil if absent.
Malformed JSON signals an error instead of implying an empty index."
  (let ((file (org-wiki-qmd--path name)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-buffer :object-type 'plist :array-type 'list
                           :null-object nil :false-object nil)))))

(defun org-wiki-qmd--write (name data)
  "Atomically write DATA to owned JSON file NAME."
  (org-wiki-qmd--write-text name (concat (json-serialize data) "\n")))

(defun org-wiki-qmd--write-text (name text)
  "Atomically replace owned file NAME with TEXT."
  (let* ((file (org-wiki-qmd--path name))
         (coding-system-for-write 'utf-8-unix)
         (temp (make-temp-file (concat file ".tmp-"))))
    (unwind-protect
        (progn (write-region text nil temp nil 'silent)
               (rename-file temp file t))
      (when (file-exists-p temp) (delete-file temp)))))

(defun org-wiki-qmd--digest (name)
  "Return a byte hash of owned file NAME, or nil when absent."
  (when (file-exists-p (org-wiki-qmd--path name))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally (org-wiki-qmd--path name))
      (secure-hash 'sha256 (current-buffer)))))

(defun org-wiki-qmd--owner ()
  "Return the owner description expected for this cache."
  (list :identity (org-wiki-qmd--identity) :index (org-wiki-qmd--index)
        :collection org-wiki-qmd-collection :format 1))

(defun org-wiki-qmd--check-owner ()
  "Reject a cache not owned by this integration and knowledge base."
  (unless (equal (org-wiki-qmd--owner) (org-wiki-qmd--read "owner.json"))
    (user-error "QMD cache owner mismatch; run setup with a dedicated cache"))
  (dolist (name '("nodes" "config" "qmd" "runtime" "maintenance.lock"
                  "owner.json" "setup.json" "state.json" "manifest.json"))
    (when (file-symlink-p (org-wiki-qmd--path name))
      (error "Symlink in owned qmd cache: %s" name))))

(defun org-wiki-qmd--check-setup ()
  "Require the owned, unchanged qmd configuration."
  (let ((setup (org-wiki-qmd--read "setup.json")))
    (unless (and setup
                 (member (plist-get setup :version) org-wiki-qmd--versions)
                 (equal (plist-get setup :config)
                        (org-wiki-qmd--digest (concat "config/" (org-wiki-qmd--index) ".yml"))))
      (user-error "QMD configuration changed or setup incomplete; run setup"))))

(defun org-wiki-qmd--model-signature ()
  "Return file identities of configured local models.
Missing model files signal instead of triggering an implicit download."
  (secure-hash
   'sha256
   (prin1-to-string
    (mapcar (lambda (key)
              (when-let* ((path (plist-get org-wiki-qmd-models key)))
                (unless (and (file-name-absolute-p path) (file-readable-p path)
                             (file-regular-p path))
                  (user-error "QMD model %s must be a readable absolute file" key))
                (list key (file-truename path)
                      (file-attribute-size (file-attributes path))
                      (format "%s" (file-attribute-modification-time (file-attributes path))))))
            '(:embed :generate :rerank)))))

(defun org-wiki-qmd--require-models (mode)
  "Require predownloaded local models for MODE."
  (dolist (key (pcase mode
                 ('embed '(:embed))
                 ('vsearch '(:embed :generate))
                 ('query '(:embed :generate :rerank))))
    (unless (plist-get org-wiki-qmd-models key)
      (user-error "Configure local qmd model %s before %s" key mode)))
  (org-wiki-qmd--model-signature))

(defun org-wiki-qmd--alive-p (pid)
  "Return non-nil when PID is live or its liveness is uncertain."
  (or (not (integerp pid))
      (condition-case nil
          (let ((attributes (process-attributes pid)))
            ;; Exited, unreaped children cannot continue modifying the index.
            (and attributes (not (member (cdr (assq 'state attributes)) '("Z" "X")))))
        (error t))))

(defun org-wiki-qmd--acquire-lock (dir token)
  "Acquire maintenance DIR for TOKEN, serializing stale-lock reclamation.
A leftover claim directory fails closed and requires owner inspection."
  (let ((claim (org-wiki-qmd--path "maintenance.claim")))
    (condition-case nil (make-directory claim)
      (file-already-exists
       (user-error "QMD lock acquisition in progress; inspect %s" claim)))
    (unwind-protect
        (progn
          (org-wiki-qmd--write "maintenance.claim/owner.json"
                               (list :pid (emacs-pid) :host (system-name)))
          (when (file-symlink-p dir) (user-error "Symlink at qmd maintenance lock"))
          (when (file-exists-p dir)
            (let ((owner (org-wiki-qmd--read "maintenance.lock/owner.json")))
              (unless (and owner (equal (plist-get owner :host) (system-name))
                           (or (plist-get owner :finished)
                               (not (org-wiki-qmd--alive-p (plist-get owner :pid))))
                           (not (org-wiki-qmd--live-processes owner)))
                (user-error "QMD maintenance lock is held; inspect %s" dir))
              (delete-directory dir t)))
          (make-directory dir)
          (org-wiki-qmd--write
           "maintenance.lock/owner.json"
           (list :pid (emacs-pid) :host (system-name) :token token :children [])))
      (delete-directory claim t))))

(defun org-wiki-qmd--lock (function)
  "Call FUNCTION with the cross-process maintenance lock held.
Retain the lock until all recorded maintenance processes have stopped."
  (let ((dir (org-wiki-qmd--path "maintenance.lock"))
        (token (format "%s-%s" (emacs-pid) (float-time))))
    (org-wiki-qmd--acquire-lock dir token)
    (let ((org-wiki-qmd--lock-token token))
      (unwind-protect
          (funcall function)
        (let ((owner (org-wiki-qmd--read "maintenance.lock/owner.json")))
          (when (equal token (plist-get owner :token))
            (if-let* ((children (org-wiki-qmd--live-processes owner)))
                (progn
                  ;; This Emacs has finished the task, but an orphan may still
                  ;; write the index.  A retry may reclaim only after it stops.
                  (org-wiki-qmd--write
                   "maintenance.lock/owner.json"
                   (list :pid (emacs-pid) :host (system-name) :token token
                         :children (vconcat (delete-dups
                                             (append (plist-get owner :children) children)))
                         :finished t))
                  (message "QMD child processes still running; retaining lock %s" dir))
              (delete-directory dir t))))))))

(defun org-wiki-qmd--children (pid)
  "Return descendants of PID, including reparented process-group members.
On POSIX systems Emacs starts pipe subprocesses in their own process group."
  (let ((parents (list pid)) found)
    (while parents
      (let ((parent (pop parents)))
        (dolist (child (list-system-processes))
          (let ((attributes (process-attributes child)))
            (when (and (not (equal child pid)) (not (memq child found))
                       (or (equal parent (cdr (assq 'ppid attributes)))
                           (and (equal parent pid)
                                (equal pid (cdr (assq 'pgrp attributes))))))
              (push child found)
              (push child parents))))))
    found))

(defun org-wiki-qmd--live-processes (owner)
  "Return live or uncertain maintenance processes recorded by OWNER.
Check process groups too: a launcher can exit before its children are polled."
  (let ((children (plist-get owner :children)))
    (delete-dups
     (seq-filter #'org-wiki-qmd--alive-p
                 (append children
                         (mapcan (lambda (pid)
                                   (when (integerp pid) (org-wiki-qmd--children pid)))
                                 children))))))

(defun org-wiki-qmd--record-process (process)
  "Record PROCESS and its children while holding a maintenance lock."
  (when org-wiki-qmd--lock-token
    (let ((children
           (delete-dups
            (append (org-wiki-qmd--live-processes
                     (org-wiki-qmd--read "maintenance.lock/owner.json"))
                    (cons (process-id process)
                          (org-wiki-qmd--children (process-id process)))))))
      ;; Keep previously observed descendants even after they are reparented.
      (org-wiki-qmd--write
       "maintenance.lock/owner.json"
       (list :pid (emacs-pid) :host (system-name)
             :token org-wiki-qmd--lock-token :children (vconcat children))))))

(defun org-wiki-qmd--check-output (stdout stderr)
  "Signal when the combined bytes in STDOUT and STDERR exceed the limit."
  (when (> (+ (with-current-buffer stdout (1- (position-bytes (point-max))))
              (with-current-buffer stderr (1- (position-bytes (point-max)))))
           org-wiki-qmd-output-limit)
    (error "QMD output limit exceeded")))

(defun org-wiki-qmd--run (args timeout)
  "Run qmd with argument list ARGS and TIMEOUT seconds.
Use pipes, isolated paths, bounded output, and interruptible waiting.
Return stdout; signal on failure and propagate user quits."
  (unless (and (numberp timeout) (> timeout 0))
    (error "QMD timeout must be positive"))
  (let* ((default-directory (org-wiki-qmd--directory))
         (process-environment (copy-sequence process-environment))
         (coding-system-for-read 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (stdout (generate-new-buffer " *org-wiki-qmd-out*"))
         (stderr (generate-new-buffer " *org-wiki-qmd-err*"))
         (deadline (+ (float-time) timeout))
         (next-report 0)
         process)
    (setenv "QMD_CONFIG_DIR" (org-wiki-qmd--path "config"))
    (setenv "INDEX_PATH" (org-wiki-qmd--path "qmd/index.sqlite"))
    (setenv "XDG_CACHE_HOME" (org-wiki-qmd--path "runtime"))
    (setenv "PWD" default-directory)
    (dolist (pair '((:embed . "QMD_EMBED_MODEL")
                    (:generate . "QMD_GENERATE_MODEL") (:rerank . "QMD_RERANK_MODEL")))
      (setenv (cdr pair) (plist-get org-wiki-qmd-models (car pair))))
    (unwind-protect
        (progn
          (setq process
                (make-process :name "org-wiki-qmd" :buffer stdout :stderr stderr
                              :command (append (list org-wiki-qmd-program
                                                     "--index" (org-wiki-qmd--index))
                                               args)
                              :connection-type 'pipe :noquery t
                              :sentinel #'ignore))
          ;; Record even a launcher that exits before the first polling cycle.
          (org-wiki-qmd--record-process process)
          (while (process-live-p process)
            (when (and org-wiki-qmd--lock-token (> (float-time) next-report))
              (org-wiki-qmd--record-process process)
              (setq next-report (+ (float-time) 1))
              (with-current-buffer stderr
                (unless (zerop (buffer-size))
                  (message "org-wiki qmd: %s"
                           (string-trim (buffer-substring-no-properties
                                         (max (point-min) (- (point-max) 160)) (point-max)))))))
            (when (> (float-time) deadline) (error "QMD timed out"))
            (org-wiki-qmd--check-output stdout stderr)
            (accept-process-output process 0.05))
          ;; Drain the separate stderr pipe, including short-lived commands.
          (accept-process-output nil 0.01)
          (org-wiki-qmd--check-output stdout stderr)
          (unless (and (eq (process-status process) 'exit)
                       (= (process-exit-status process) 0))
            (error "QMD failed: %s"
                   (with-current-buffer stderr
                     (string-trim (buffer-substring-no-properties
                                   (point-min) (min (point-max) (+ (point-min) 2000)))))))
          (when (and org-wiki-qmd--lock-token
                     (org-wiki-qmd--live-processes
                      (org-wiki-qmd--read "maintenance.lock/owner.json")))
            (error "QMD exited with maintenance child processes still running"))
          (with-current-buffer stdout (buffer-string)))
      (when (and process (process-live-p process))
        (dolist (pid (org-wiki-qmd--children (process-id process)))
          (ignore-errors (signal-process pid 'SIGKILL)))
        (delete-process process))
      (when-let* ((pipe (get-buffer-process stderr))) (delete-process pipe))
      (kill-buffer stdout)
      (kill-buffer stderr))))

(defun org-wiki-qmd--root-files (directory)
  "Recursively enumerate Org files in DIRECTORY, failing on unreadable dirs.
Do not follow directory symlinks, matching the read-side discovery scope."
  (unless (and (file-readable-p directory) (file-accessible-directory-p directory))
    (error "QMD discovery: unreadable directory %s" directory))
  (let (files)
    (dolist (file (directory-files directory t directory-files-no-dot-files-regexp))
      (cond ((file-directory-p file)
             (unless (file-symlink-p file)
               (setq files (nconc files (org-wiki-qmd--root-files file)))))
            ((string-suffix-p ".org" file) (push file files))))
    files))

(defun org-wiki-qmd--discover ()
  "Return completely discovered files, or signal without modifying caches."
  (unless (file-directory-p org-wiki-root)
    (error "QMD discovery: wiki root does not exist"))
  (let ((files (org-wiki-qmd--root-files org-wiki-root)))
    (when (eq org-wiki-qmd-discovery-scope 'root-and-roam)
      (unless (and (fboundp 'org-roam-db-query)
                   (boundp 'org-roam-db-location)
                   org-roam-db-location
                   (file-readable-p org-roam-db-location))
        (error "QMD discovery: org-roam database unavailable; use root-only explicitly"))
      ;; Do not call the read-side helper: it intentionally swallows DB errors.
      (pcase-dolist (`(,file ,properties)
                     (org-roam-db-query
                      [:select :distinct [file properties] :from nodes]))
        (when (assoc "WIKI_KIND" properties) (push file files))))
    (sort (delete-dups (mapcar #'file-truename files)) #'string<)))

(defun org-wiki-qmd--source-text (file)
  "Read saved FILE without executing file-local variables or mode hooks.
Reject unsaved visiting buffers, including buffers visiting symlinks."
  (dolist (buffer (buffer-list))
    (when (and (buffer-file-name buffer)
               (not (file-remote-p (buffer-file-name buffer)))
               (equal (file-truename (buffer-file-name buffer)) file)
               (buffer-modified-p buffer))
      (error "QMD sync: unsaved buffer for %s" file)))
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun org-wiki-qmd--script-file (file)
  "Return the checked path of a script referenced by the memory node in FILE."
  (when (and (not (org-at-heading-p)) (member (org-entry-get nil "WIKI_KIND") org-wiki-memory-kinds)
             (org-entry-get nil "SCRIPT_PATH"))
    (require 'org-wiki-memory)
    (org-wiki-memory--script-file file (org-entry-get nil "SCRIPT_ROOT") (org-entry-get nil "SCRIPT_PATH"))))

(defun org-wiki-qmd--markdown (&optional file script)
  "Render the wiki node at point as inert Markdown, using FILE for its name.
Include saved SCRIPT text when the node references a verification script."
  (let ((title (if (org-at-heading-p) (org-get-heading t t t t)
                 (org-wiki--file-title file)))
        (level (org-outline-level))
        (kind (org-wiki--canonical-kind (org-entry-get nil "WIKI_KIND")))
        (body (org-wiki--owned-body)))
    (with-temp-buffer
      (insert body)
      (delay-mode-hooks (org-mode))
      ;; Apply disjoint AST edits backwards.  Code is literal: apparent links,
      ;; headings, drawers and INCLUDE directives inside blocks stay intact.
      (let (edits)
        (org-element-map (org-element-parse-buffer)
            '(property-drawer keyword headline src-block example-block link)
          (lambda (element)
            (let* ((type (org-element-type element))
                   (begin (org-element-property :begin element))
                   (end (org-element-property :end element))
                   (post-blank (or (org-element-property :post-blank element) 0))
                   (replacement
                    (pcase type
                      ((or 'property-drawer 'keyword) "")
                      ('headline
                       (setq end (+ begin (org-element-property :level element)))
                       (make-string (min 6 (1+ (- (org-element-property :level element) level))) ?#))
                      ((or 'src-block 'example-block)
                       (concat "```" (or (org-element-property :language element) "") "\n"
                               (org-element-property :value element) "```\n"
                               (make-string post-blank ?\n)))
                      ('link
                       (concat (if (org-element-property :contents-begin element)
                                   (buffer-substring-no-properties
                                    (org-element-property :contents-begin element)
                                    (org-element-property :contents-end element))
                                 (org-element-property :raw-link element))
                               (make-string post-blank ?\s))))))
              (push (list begin end replacement) edits))))
        (dolist (edit (sort edits (lambda (a b) (> (car a) (car b)))))
          (goto-char (car edit))
          (delete-region (car edit) (nth 1 edit))
          (insert (nth 2 edit))))
      (concat "# " title "\n\nKind: " kind "\n\n"
              (string-trim (buffer-string)) "\n"
              (when script (concat "\n" script))))))

(defun org-wiki-qmd--snapshot (files)
  "Build a validated in-memory snapshot of saved FILES.
Return nodes and file hashes; report and exclude all duplicate IDs."
  (let ((by-id (make-hash-table :test #'equal)) nodes sources)
    (setq org-wiki-qmd--diagnostics nil)
    (dolist (file files)
      (let ((text (org-wiki-qmd--source-text file)))
        (push (list :file file :hash (secure-hash 'sha256 text)) sources)
        (with-temp-buffer
          (insert text)
          (delay-mode-hooks (org-mode))
          (dolist (pos (org-wiki--node-positions))
            (goto-char pos)
            (if-let* ((id (org-entry-get nil "ID")))
                (let* ((script-file (org-wiki-qmd--script-file file))
                       (script (when script-file (org-wiki-qmd--source-text script-file)))
                       (markdown (org-wiki-qmd--markdown file script))
                       (node (list :id id :file file
                                   :path (concat (secure-hash 'sha256 id) ".md")
                                   :hash (secure-hash 'sha256 markdown)
                                   :text markdown)))
                  (when script-file
                    (push (list :file script-file :hash (secure-hash 'sha256 script)) sources))
                  (puthash id (cons node (gethash id by-id)) by-id))
              (push (format "Missing ID: %s:%s" file (line-number-at-pos))
                    org-wiki-qmd--diagnostics))))))
    (maphash (lambda (id entries)
               (if (cdr entries)
                   (push (format "Duplicate ID: %s" id) org-wiki-qmd--diagnostics)
                 (push (car entries) nodes))) by-id)
    (list :nodes (sort nodes (lambda (a b) (string< (plist-get a :path)
                                                    (plist-get b :path))))
          :sources sources)))

(defun org-wiki-qmd--sources-unchanged-p (sources)
  "Return non-nil if saved SOURCES still match their snapshot hashes."
  (seq-every-p
   (lambda (source)
     (equal (plist-get source :hash)
            (secure-hash 'sha256
                         (org-wiki-qmd--source-text (plist-get source :file)))))
   sources))

(defun org-wiki-qmd--ready ()
  "Return matching state and manifest, or nil when not ready.
This function starts no external processes and creates no files."
  (org-wiki-qmd--check-owner)
  (org-wiki-qmd--check-setup)
  (unless (or (file-exists-p (org-wiki-qmd--path "maintenance.lock"))
              (file-exists-p (org-wiki-qmd--path "maintenance.claim")))
    (let ((state (org-wiki-qmd--read "state.json"))
          (manifest (org-wiki-qmd--read "manifest.json")))
      (when (and (equal (plist-get state :status) "ready")
                 (equal (plist-get state :generation) (plist-get manifest :generation))
                 (equal (plist-get state :manifest) (org-wiki-qmd--digest "manifest.json"))
                 (equal (plist-get manifest :identity) (org-wiki-qmd--identity))
                 (equal (plist-get manifest :scope) (symbol-name org-wiki-qmd-discovery-scope))
                 (file-exists-p (org-wiki-qmd--path "qmd/index.sqlite"))
                 (or (eq org-wiki-qmd-search-mode 'search)
                     (and (org-wiki-qmd--require-models org-wiki-qmd-search-mode)
                          (equal (plist-get state :models) (org-wiki-qmd--model-signature))
                          (equal (plist-get state :embedded) (plist-get state :generation)))))
        (cons state manifest)))))

(defun org-wiki-qmd--setup ()
  "Prepare an owned collection under the maintenance lock."
  (let* ((output (string-trim (org-wiki-qmd--run '("--version") 10)))
         (version (cadr (split-string output))))
    (unless (member version org-wiki-qmd--versions)
      (error "Unsupported qmd version: %s" output))
    (make-directory (org-wiki-qmd--path "config") t)
    (make-directory (org-wiki-qmd--path "qmd") t)
    (make-directory (org-wiki-qmd--path "nodes") t)
    ;; JSON is valid YAML.  Generate only our collection, with no update hooks.
    ;; Rewriting the same config also repairs setup interrupted after creation.
    (let* ((config (concat "config/" (org-wiki-qmd--index) ".yml"))
           (collections (make-hash-table :test #'equal))
           (unchanged (condition-case nil
                          (progn (org-wiki-qmd--check-setup) t)
                        (error nil))))
      (unless unchanged
        (org-wiki-qmd--write "state.json" (list :status "updating"))
        (puthash org-wiki-qmd-collection
                 (list :path (org-wiki-qmd--path "nodes") :pattern "*.md") collections)
        (org-wiki-qmd--write config (list :collections collections))
        (org-wiki-qmd--run '("update") org-wiki-qmd-maintenance-timeout))
      (unless (and unchanged (equal version (plist-get (org-wiki-qmd--read "setup.json") :version)))
        (org-wiki-qmd--write "setup.json" (list :version version :config (org-wiki-qmd--digest config)))))))

;;;###autoload
(defun org-wiki-qmd-setup ()
  "Create the dedicated qmd collection without enabling search.
Require the verified CLI version.  Signal on configuration or ownership errors."
  (interactive)
  (org-wiki-qmd--validate-config)
  (make-directory (org-wiki-qmd--directory) t)
  (org-wiki-qmd--lock
   (lambda ()
     (if (org-wiki-qmd--read "owner.json")
         (org-wiki-qmd--check-owner)
       (unless (equal (directory-files (org-wiki-qmd--directory) nil directory-files-no-dot-files-regexp)
                      '("maintenance.lock"))
         (user-error "QMD cache must be empty before setup"))
       (org-wiki-qmd--write "owner.json" (org-wiki-qmd--owner)))
     (org-wiki-qmd--setup)))
  (when (called-interactively-p 'interactive)
    (message "org-wiki: qmd collection prepared; run org-wiki-qmd-sync")))

(defun org-wiki-qmd--sync ()
  "Synchronize a complete snapshot with the maintenance lock held."
  (org-wiki-qmd--check-setup)
  (let* ((files (org-wiki-qmd--discover))
         (snapshot (org-wiki-qmd--snapshot files))
         (nodes (plist-get snapshot :nodes))
         (models (plist-get (org-wiki-qmd--read "state.json") :models))
         (generation (format "%s-%s" (emacs-pid) (float-time))))
    (org-wiki-qmd--write "state.json"
                         (list :status "updating" :generation generation :models models))
    (dolist (node nodes)
      (let ((path (concat "nodes/" (plist-get node :path))))
        (unless (equal (org-wiki-qmd--digest path) (plist-get node :hash))
          (org-wiki-qmd--write-text path (plist-get node :text)))))
    ;; Include files from an interrupted, not-yet-committed generation.  The
    ;; directory is exclusively owned; never follow symlinks during deletion.
    (dolist (path (directory-files (org-wiki-qmd--path "nodes") nil
                                   "\\`[a-f0-9]\\{64\\}\\.md\\'"))
      (unless (seq-find (lambda (node) (equal path (plist-get node :path))) nodes)
        (let ((file (org-wiki-qmd--path (concat "nodes/" path))))
          (when (file-symlink-p file) (error "Symlink in owned qmd nodes"))
          (delete-file file))))
    (org-wiki-qmd--run '("update") org-wiki-qmd-maintenance-timeout)
    (unless (and (file-exists-p (org-wiki-qmd--path "qmd/index.sqlite"))
                 (equal files (org-wiki-qmd--discover))
                 (org-wiki-qmd--sources-unchanged-p (plist-get snapshot :sources)))
      (error "QMD source snapshot changed during update; sync again"))
    (org-wiki-qmd--write
     "manifest.json"
     (list :identity (org-wiki-qmd--identity) :scope (symbol-name org-wiki-qmd-discovery-scope)
           :generation generation :format 1
           :sources (vconcat (plist-get snapshot :sources))
           :nodes (vconcat (mapcar (lambda (node)
                                     (list :id (plist-get node :id) :file (plist-get node :file)
                                           :path (plist-get node :path) :hash (plist-get node :hash)))
                                   nodes))))
    (org-wiki-qmd--write
     "state.json"
     (list :status "ready" :generation generation :time (float-time)
           :manifest (org-wiki-qmd--digest "manifest.json") :embedded nil :models models))
    (dolist (node nodes)
      (condition-case err
          (org-wiki-qmd--validate-node node)
        (error (push (error-message-string err) org-wiki-qmd--diagnostics))))))

;;;###autoload
(defun org-wiki-qmd-sync ()
  "Index saved wiki nodes without changing any source file.
Abort before modifying caches if discovery is incomplete or buffers are dirty.
Interrupted updates remain unready until a complete sync succeeds."
  (interactive)
  (org-wiki-qmd--validate-config)
  (condition-case err
      (progn (org-wiki-qmd--check-owner)
             (org-wiki-qmd--lock #'org-wiki-qmd--sync)
             (setq org-wiki-qmd-last-error nil))
    (error (setq org-wiki-qmd-last-error (error-message-string err))
           (signal (car err) (cdr err))))
  (when (called-interactively-p 'interactive) (org-wiki-qmd-status)))

;;;###autoload
(defun org-wiki-qmd-embed ()
  "Explicitly build vectors for the committed document generation.
Require local GGUF paths in `org-wiki-qmd-models'.
Failed embedding leaves qmd unready; run sync to recover keyword search."
  (interactive)
  (org-wiki-qmd--validate-config)
  (org-wiki-qmd--require-models 'embed)
  (let* ((models (org-wiki-qmd--model-signature))
         (org-wiki-qmd-search-mode 'search)
         (ready (org-wiki-qmd--ready)))
    (unless ready (user-error "Run a successful qmd sync first"))
    (org-wiki-qmd--lock
     (lambda ()
       (unless (equal (car ready) (org-wiki-qmd--read "state.json"))
         (error "QMD generation changed before embedding"))
       (org-wiki-qmd--write "state.json" (list :status "updating"))
       (message "org-wiki: preparing qmd embeddings using local models...")
       ;; qmd keys vectors by model path, not the bytes behind that path.
       ;; Missing provenance (including interrupted embedding) also rebuilds.
       (org-wiki-qmd--run (append (list "embed" "-c" org-wiki-qmd-collection)
                                  (unless (equal models (plist-get (car ready) :models))
                                    '("--force")))
                          org-wiki-qmd-maintenance-timeout)
       (unless (equal models (org-wiki-qmd--model-signature))
         (error "QMD models changed during embedding; embed again after sync"))
       (let ((state (copy-sequence (car ready))))
         (setq state (plist-put state :embedded (plist-get state :generation)))
         (setq state (plist-put state :models (org-wiki-qmd--model-signature)))
         (org-wiki-qmd--write "state.json" state))))))

(defun org-wiki-qmd--file-has-node-p (file id)
  "Return non-nil when saved FILE has a wiki node with the exact ID."
  (with-temp-buffer
    (insert (org-wiki-qmd--source-text (file-truename file)))
    (delay-mode-hooks (org-mode))
    (seq-some (lambda (pos) (equal id (org-entry-get pos "ID")))
              (org-wiki--node-positions))))

(defun org-wiki-qmd--validate-node (node)
  "Return the current summary for NODE and register its verified ID.
Reject stale bodies, dirty visiting buffers, and conflicting live ID locations."
  (let* ((file (file-truename (plist-get node :file)))
         (id (plist-get node :id))
         (saved (org-wiki-qmd--source-text file)))
    (with-current-buffer (org-wiki--node-buffer file)
      (save-restriction
        (widen)
        (when (buffer-modified-p) (error "Unsaved qmd source buffer"))
        ;; External tools can preserve mtimes and sizes.  Compare saved text,
        ;; not just Emacs's visited-file timestamp, before trusting a live buffer.
        (unless (equal saved (buffer-substring-no-properties (point-min) (point-max)))
          (let ((revert-without-query (list "."))) (revert-buffer t t t)))
        (unless (and (not (buffer-modified-p))
                     (equal saved (buffer-substring-no-properties (point-min) (point-max))))
          (error "QMD source changed during validation"))
        (save-excursion
          (unless (equal id (org-wiki--goto-id id)) (error "Non-canonical qmd ID"))
          (let* ((script-file (org-wiki-qmd--script-file file))
                 (script (when script-file (org-wiki-qmd--source-text script-file))))
            (unless (and (equal id (org-entry-get nil "ID"))
                         (org-wiki-node-p)
                         (equal (plist-get node :hash)
                                (secure-hash 'sha256 (org-wiki-qmd--markdown file script))))
              (error "Stale qmd node: %s" id)))
          (when-let* ((old (and (hash-table-p org-id-locations) (gethash id org-id-locations))))
            (when (and (file-exists-p old) (not (equal file (file-truename old)))
                       (org-wiki-qmd--file-has-node-p old id))
              (error "Conflicting ID location: %s" id)))
          (unless (hash-table-p org-id-locations)
            (setq org-id-locations (make-hash-table :test #'equal)))
          (puthash id file org-id-locations)
          (org-wiki--node-at-point-summary))))))

(defun org-wiki-qmd--hit-path (hit)
  "Return the cache basename for JSON HIT, rejecting foreign paths."
  (let ((file (plist-get hit :file)))
    (unless (stringp file) (error "QMD result lacks a string file field"))
    (when (string-match
           "\\`qmd://\\([^/]+\\)/\\([a-f0-9]\\{64\\}\\.md\\)\\(?:\\?index=\\([^?&#]+\\)\\)?\\'"
           file)
      (when (and (equal (match-string 1 file) org-wiki-qmd-collection)
                 (or (equal (match-string 3 file) (org-wiki-qmd--index))
                     (and (not (match-string 3 file))
                          (equal (org-wiki-qmd--index) "index"))))
        (match-string 2 file)))))

(defun org-wiki-qmd--search (query k &optional select)
  "Return verified summaries for QUERY, at most K, in qmd rank order.
When supplied, SELECT takes a manifest node and returns a verified result
or nil to skip the candidate.  Signal when unready.  User quits propagate."
  (org-wiki-qmd--validate-config)
  (let* ((select (or select #'org-wiki-qmd--validate-node))
         (ready (org-wiki-qmd--ready))
         (deadline (+ (float-time) org-wiki-qmd-search-timeout))
         (limit (min 1000 (max 20 (* 4 k))))
         (maximum (min 1000 (max 100 (* 10 k))))
         results done)
    (unless ready (error "QMD is not ready for %s; run sync or embed" org-wiki-qmd-search-mode))
    (while (not done)
      (let* ((output (org-wiki-qmd--run
                      (list (symbol-name org-wiki-qmd-search-mode)
                            "--format" "json" "-c" org-wiki-qmd-collection
                            "-n" (number-to-string limit) "--" query)
                      (- deadline (float-time))))
             (hits (json-parse-string output :object-type 'plist :array-type 'array
                                      :null-object nil :false-object nil))
             (seen (make-hash-table :test #'equal)))
        (unless (vectorp hits) (error "QMD search JSON must be an array"))
        (setq results nil)
        (seq-doseq (hit hits)
          (when (> (float-time) deadline) (error "QMD search validation timed out"))
          (when-let* ((path (org-wiki-qmd--hit-path hit))
                      (node (seq-find (lambda (entry) (equal path (plist-get entry :path)))
                                      (plist-get (cdr ready) :nodes)))
                      (id (plist-get node :id)))
            (unless (gethash id seen)
              (puthash id t seen)
              (condition-case nil
                  (when-let* ((result (funcall select node)))
                    (push result results))
                (error nil)))))
        (setq results (nreverse results))
        (if (or (>= (length results) k) (< (length hits) limit) (>= limit maximum))
            (setq done t)
          (setq limit (min maximum (* 2 limit))))))
    (when (> (float-time) deadline) (error "QMD search validation timed out"))
    (unless (equal ready (org-wiki-qmd--ready))
      (error "QMD generation changed during search"))
    (setq org-wiki-qmd-last-error (unless results "No valid qmd matches"))
    (seq-take results k)))

;;;###autoload
(defun org-wiki-qmd-status ()
  "Return local qmd status as a plist and display it interactively.
Never start a process, even when search is disabled."
  (interactive)
  (let* ((problem nil)
         (ready (if (not org-wiki-qmd-collection)
                    (progn (setq problem "Not configured") nil)
                  (condition-case err (org-wiki-qmd--ready)
                    (error (setq problem (error-message-string err)) nil))))
         (pending (and ready
                       (not (condition-case nil
                                (org-wiki-qmd--sources-unchanged-p
                                 (plist-get (cdr ready) :sources))
                              (error nil)))))
         (status (list :enabled org-wiki-qmd-enabled :ready (and ready t)
                       :pending-sync pending
                       :mode org-wiki-qmd-search-mode
                       :nodes (length (plist-get (cdr ready) :nodes))
                       :time (plist-get (car ready) :time)
                       :reason (or problem
                                   (when pending "Sources changed; run sync")
                                   org-wiki-qmd-last-error
                                   (when (and (not ready)
                                              (file-exists-p (org-wiki-qmd--path "maintenance.lock")))
                                     "Maintenance in progress")
                                   (when (and (not ready) (not (eq org-wiki-qmd-search-mode 'search)))
                                     "Needs embedding for the current document generation")
                                   (unless ready "Not synced or needs embedding"))
                       :diagnostics org-wiki-qmd--diagnostics)))
    (when (called-interactively-p 'interactive)
      (message "org-wiki qmd: %s; %s; %s nodes%s"
               (if org-wiki-qmd-enabled "enabled" "disabled")
               (if ready "ready" "unready") (plist-get status :nodes)
               (if (plist-get status :reason) (concat "; " (plist-get status :reason)) "")))
    status))

(provide 'org-wiki-qmd)
;;; org-wiki-qmd.el ends here
