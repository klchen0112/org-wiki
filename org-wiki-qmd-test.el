;;; org-wiki-qmd-test.el --- Tests for optional qmd search -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Hermetic lifecycle tests use an in-memory CLI adapter.  Process tests
;; use short shell scripts; a separate opt-in integration target uses qmd.

;;; Code:

(require 'ert)
(require 'org-wiki-qmd)
(defvar org-roam-db-location nil)

(defvar org-wiki-qmd-test--calls nil)
(defvar org-wiki-qmd-test--fail nil)
(defvar org-wiki-qmd-test--output nil)

(defconst org-wiki-qmd-test--source
  "#+title: Mixed file\n* Parent\n:PROPERTIES:\n:ID: parent\n:WIKI_KIND: Concept\n:END:\n** Summary\nParent summary. [[id:child][Child label]]\n*** Child\n:PROPERTIES:\n:ID: child\n:WIKI_KIND: Topic\n:END:\n**** Summary\nChild secret keyword.\n** Definition\n#+INCLUDE: \"/do/not/read\"\n#+begin_src sh\nprintf example\n#+end_src\n* Ordinary\nOutside wiki keyword.\n")

(defmacro org-wiki-qmd-test--fixture (&rest body)
  "Run BODY with an isolated source tree and owned cache."
  (declare (indent 0))
  `(let* ((base (make-temp-file "org-wiki-qmd-test-" t))
          (org-wiki-root (expand-file-name "org" base))
          (org-wiki-qmd-cache-directory (expand-file-name "cache" base))
          (org-wiki-qmd-collection "wiki")
          (org-wiki-qmd-index-name "wiki-test")
          (org-wiki-qmd-discovery-scope 'root-only)
          (org-wiki-qmd-search-mode 'search)
          (org-wiki-qmd-enabled t)
          (org-wiki-search-backend 'qmd)
          (org-wiki-qmd-models nil)
          (org-wiki-qmd-last-error nil)
          (org-wiki-qmd--diagnostics nil)
          (org-id-locations (make-hash-table :test #'equal))
          (org-id-locations-file (expand-file-name "ids" base))
          (org-wiki-qmd-test--calls nil)
          (org-wiki-qmd-test--fail nil)
          (org-wiki-qmd-test--output nil)
          (source (expand-file-name "sample.org" org-wiki-root)))
     (make-directory org-wiki-root)
     (with-temp-file source (insert org-wiki-qmd-test--source))
     (unwind-protect (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (file-in-directory-p (buffer-file-name buffer) base))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory base t))))

(defun org-wiki-qmd-test--run (args _timeout)
  "Emulate CLI ARGS while recording calls and honoring failure controls."
  (push args org-wiki-qmd-test--calls)
  (when (equal (car args) org-wiki-qmd-test--fail) (error "Simulated CLI failure"))
  (pcase (car args)
    ("--version" "qmd 2.8.3 (facd35e)\n")
    ("update"
     (with-temp-file (org-wiki-qmd--path "qmd/index.sqlite") (insert "fixture")) "")
    ("embed" "")
    (_ (or org-wiki-qmd-test--output
           (json-serialize
            (vconcat
             (mapcar (lambda (node)
                       (list :file (concat "qmd://wiki/" (plist-get node :path)
                                           "?index=wiki-test") :score 0.9))
                     (plist-get (org-wiki-qmd--read "manifest.json") :nodes))))))))

(defmacro org-wiki-qmd-test--index (&rest body)
  "Run BODY after preparing an isolated fake-CLI index."
  (declare (indent 0))
  `(org-wiki-qmd-test--fixture
    (cl-letf (((symbol-function 'org-wiki-qmd--run) #'org-wiki-qmd-test--run))
      (org-wiki-qmd-setup)
      (org-wiki-qmd-sync)
      ,@body)))

(ert-deftest org-wiki-qmd-test-owned-content-and-summary ()
  (org-wiki-qmd-test--index
   (let* ((nodes (plist-get (org-wiki-qmd--read "manifest.json") :nodes))
          (parent (seq-find (lambda (node) (equal (plist-get node :id) "parent")) nodes))
          (child (seq-find (lambda (node) (equal (plist-get node :id) "child")) nodes))
          (text (with-temp-buffer
                  (insert-file-contents (org-wiki-qmd--path (concat "nodes/" (plist-get parent :path))))
                  (buffer-string))))
     (should (= (length nodes) 2))
     (should (string-match-p "Child label" text))
     (should (string-match-p "```sh\nprintf example\n```" text))
     (should-not (string-match-p "Child secret\\|Outside wiki\\|PROPERTIES\\|INCLUDE" text))
     (should (equal (plist-get (org-wiki-qmd--validate-node child) :summary)
                    "Child secret keyword."))
     (should (equal (plist-get (org-wiki-qmd--validate-node parent) :summary)
                    "Parent summary. [[id:child][Child label]]"))
     (should (equal (org-wiki-qmd--source-text source) org-wiki-qmd-test--source)))))

(ert-deftest org-wiki-qmd-test-summary-only-direct-ordinary-first ()
  (with-temp-buffer
    (insert "* Parent\n:PROPERTIES:\n:WIKI_KIND: Topic\n:END:\n** Other\n*** Summary\nWrong descendant.\n** Summary\n:PROPERTIES:\n:WIKI_KIND: Topic\n:END:\nWrong wiki.\n** Summary\nFirst ordinary.\n** Summary\nSecond ordinary.\n")
    (org-mode) (goto-char (point-min))
    (should (equal (org-wiki--extract-summary) "First ordinary."))))

(ert-deftest org-wiki-qmd-test-no-borrowed-summary ()
  (with-temp-buffer
    (insert "* Parent\n** Child\n*** Summary\nChild summary.\n")
    (org-mode) (goto-char (point-min))
    (should (equal (org-wiki--extract-summary) ""))))

(ert-deftest org-wiki-qmd-test-search-read-cold-and-stale-id-table ()
  (org-wiki-qmd-test--index
   (clrhash org-id-locations)
   (puthash "child" (expand-file-name "gone.org" base) org-id-locations)
   (let ((results (org-wiki--search "keyword" 10)))
     (should (= 2 (length results)))
     (dolist (node results)
       (should (equal (plist-get node :file) (file-truename source)))
       (should (equal (org-wiki-canonical-id (plist-get node :id)) (plist-get node :id))))
     (should (string-match-p "Child secret" (org-wiki-read-node "child"))))))

(ert-deftest org-wiki-qmd-test-disable-overrides-qmd-backend ()
  (org-wiki-qmd-test--index
   (setq org-wiki-qmd-test--calls nil)
   (let ((org-wiki-qmd-enabled nil))
     (should (org-wiki--search "Parent"))
     (should-not org-wiki-qmd-test--calls)
     (should (equal org-wiki-qmd-last-error "Search disabled"))
     (should (plist-get (org-wiki-qmd-status) :ready)))
   (should (org-wiki--search "keyword"))
   (should org-wiki-qmd-test--calls)))

(ert-deftest org-wiki-qmd-test-auto-fallback-and-text-bypass ()
  (org-wiki-qmd-test--index
   (let ((org-wiki-search-backend 'auto)
         (org-wiki-qmd-enabled nil))
     (cl-letf (((symbol-function 'org-wiki--semantic-available-p) (lambda () t))
               ((symbol-function 'org-wiki--semantic-search) (lambda (&rest _) '((:id "semantic")))))
       (should (equal (plist-get (car (org-wiki--search "anything")) :id) "semantic"))))
   (let ((org-wiki-search-backend 'text))
     (setq org-wiki-qmd-test--calls nil)
     (should (org-wiki--search "Parent"))
     (should-not org-wiki-qmd-test--calls))))

(ert-deftest org-wiki-qmd-test-empty-query-bypasses-backends ()
  (org-wiki-qmd-test--index
   (setq org-wiki-qmd-test--calls nil)
   (should (org-wiki--search ""))
   (should-not org-wiki-qmd-test--calls)))

(ert-deftest org-wiki-qmd-test-invalid-output-falls-back ()
  (org-wiki-qmd-test--index
   (dolist (output '("broken" "{}" "[{}]" "[]"))
     (let ((org-wiki-qmd-test--output output))
       (should (org-wiki--search "Parent"))
       (should org-wiki-qmd-last-error)))))

(ert-deftest org-wiki-qmd-test-quit-propagates-without-fallback ()
  (org-wiki-qmd-test--index
   (cl-letf (((symbol-function 'org-wiki-qmd--run) (lambda (&rest _) (signal 'quit nil)))
             ((symbol-function 'org-wiki--text-search) (lambda (&rest _) (ert-fail "Fallback after quit"))))
     (should (eq 'quit (condition-case nil (org-wiki--search "query") (quit 'quit)))))))

(ert-deftest org-wiki-qmd-test-dirty-buffer-aborts-before-publication ()
  (org-wiki-qmd-test--index
   (let ((manifest (org-wiki-qmd--digest "manifest.json"))
         (state (org-wiki-qmd--read "state.json")))
     (with-current-buffer (find-file-noselect source) (goto-char (point-max)) (insert "Unsaved"))
     (should-error (org-wiki-qmd-sync))
     (should (equal manifest (org-wiki-qmd--digest "manifest.json")))
     (should (equal state (org-wiki-qmd--read "state.json"))))))

(ert-deftest org-wiki-qmd-test-db-failure-does-not-delete-caches ()
  (org-wiki-qmd-test--index
   (let ((manifest (org-wiki-qmd--digest "manifest.json"))
         (files (directory-files (org-wiki-qmd--path "nodes")))
         (org-wiki-qmd-discovery-scope 'root-and-roam)
         (org-roam-db-location source))
     (cl-letf (((symbol-function 'org-roam-db-query) (lambda (&rest _) (error "DB offline"))))
       (should-error (org-wiki-qmd-sync)))
     (should (equal manifest (org-wiki-qmd--digest "manifest.json")))
     (should (equal files (directory-files (org-wiki-qmd--path "nodes")))))
   (let ((org-wiki-qmd-discovery-scope 'root-and-roam)
         (org-roam-db-location nil))
     (should-error (org-wiki-qmd-sync)))))

(ert-deftest org-wiki-qmd-test-outside-root-and-symlink-deduplication ()
  (org-wiki-qmd-test--fixture
   (let* ((external (expand-file-name "external.org" base))
          (org-roam-db-location source)
          (org-wiki-qmd-discovery-scope 'root-and-roam))
     (with-temp-file external (insert "* Outside\n:PROPERTIES:\n:ID: outside\n:WIKI_KIND: Topic\n:END:\n** Summary\nOutside summary.\n"))
     (make-symbolic-link external (expand-file-name "link.org" org-wiki-root))
     (cl-letf (((symbol-function 'org-roam-db-query)
                (lambda (&rest _) (list (list external '(("WIKI_KIND" . "Topic"))))))
               ((symbol-function 'org-wiki-qmd--run) #'org-wiki-qmd-test--run))
       (org-wiki-qmd-setup) (org-wiki-qmd-sync)
       (clrhash org-id-locations)
       (should (= (length (org-wiki-qmd--search "anything" 10)) 3))
       (should (string-match-p "Outside summary" (org-wiki-read-node "outside")))))))

(ert-deftest org-wiki-qmd-test-incremental-delete-and-recovery ()
  (org-wiki-qmd-test--index
   (let* ((node (car (plist-get (org-wiki-qmd--read "manifest.json") :nodes)))
          (cache (org-wiki-qmd--path (concat "nodes/" (plist-get node :path))))
          (mtime (file-attribute-modification-time (file-attributes cache))))
     (org-wiki-qmd-sync)
     (should (equal mtime (file-attribute-modification-time (file-attributes cache)))))
   (let ((org-wiki-qmd-test--fail "update"))
     (should-error (org-wiki-qmd-sync)))
   (should-not (org-wiki-qmd--ready))
   (should (equal "updating" (plist-get (org-wiki-qmd--read "state.json") :status)))
   (org-wiki-qmd-sync)
   (should (org-wiki-qmd--ready))
   (kill-buffer (get-file-buffer source))
   (delete-file source)
   (org-wiki-qmd-sync)
   (should-not (plist-get (cdr (org-wiki-qmd--ready)) :nodes))
   (should-not (directory-files (org-wiki-qmd--path "nodes") nil "\\.md\\'"))))

(ert-deftest org-wiki-qmd-test-duplicates-and-missing-ids ()
  (org-wiki-qmd-test--fixture
   (with-temp-file (expand-file-name "duplicate.org" org-wiki-root)
     (insert "* Duplicate\n:PROPERTIES:\n:ID: child\n:WIKI_KIND: Topic\n:END:\n* Missing\n:PROPERTIES:\n:WIKI_KIND: Topic\n:END:\n"))
   (cl-letf (((symbol-function 'org-wiki-qmd--run) #'org-wiki-qmd-test--run))
     (org-wiki-qmd-setup) (org-wiki-qmd-sync)
     (should (= 1 (length (plist-get (cdr (org-wiki-qmd--ready)) :nodes))))
     (should (= 2 (length org-wiki-qmd--diagnostics))))))

(ert-deftest org-wiki-qmd-test-rejects-live-id-conflict ()
  (org-wiki-qmd-test--index
   (let ((other (expand-file-name "other.org" base))
         (node (car (plist-get (org-wiki-qmd--read "manifest.json") :nodes))))
     (with-temp-file other
       (insert "* Conflict\n:PROPERTIES:\n:ID: " (plist-get node :id) "\n:WIKI_KIND: Topic\n:END:\n"))
     (puthash (plist-get node :id) other org-id-locations)
     (should-error (org-wiki-qmd--validate-node node))
     (should (equal other (gethash (plist-get node :id) org-id-locations))))))

(ert-deftest org-wiki-qmd-test-repairs-nonconflicting-id-locations ()
  (org-wiki-qmd-test--index
   (let ((old (expand-file-name "old.org" base))
         (node (seq-find (lambda (entry) (equal (plist-get entry :id) "child"))
                         (plist-get (org-wiki-qmd--read "manifest.json") :nodes))))
     (dolist (text '("* Renamed\n:PROPERTIES:\n:ID: child-renamed\n:WIKI_KIND: Topic\n:END:\n"
                     "* Ordinary\n:PROPERTIES:\n:ID: child\n:END:\n"
                     "* Example\n:PROPERTIES:\n:ID: other\n:WIKI_KIND: Topic\n:END:\n#+begin_src org\n:ID: child\n#+end_src\n"
                     ":PROPERTIES:\n:ID: child\n:END:\n* Other\n:PROPERTIES:\n:ID: other\n:WIKI_KIND: Topic\n:END:\n"))
       (with-temp-file old (insert text))
       (puthash "child" old org-id-locations)
       (should (equal "child" (plist-get (org-wiki-qmd--validate-node node) :id)))
       (should (equal source (gethash "child" org-id-locations)))
       (should (string-match-p "Child secret" (org-wiki-read-node "child")))))))

(ert-deftest org-wiki-qmd-test-stale-content-and-generation-filter ()
  (org-wiki-qmd-test--index
   (with-temp-file source (insert "* Changed\n:PROPERTIES:\n:ID: parent\n:WIKI_KIND: Concept\n:END:\n** Summary\nChanged body.\n"))
   (should-not (org-wiki-qmd--search "query" 10))
   (org-wiki-qmd-sync)
   (should (equal "Changed" (plist-get (car (org-wiki-qmd--search "query" 10)) :title)))
   (let ((run (symbol-function 'org-wiki-qmd--run)))
     (cl-letf (((symbol-function 'org-wiki-qmd--run)
                (lambda (&rest args)
                  (prog1 (apply run args)
                    (org-wiki-qmd--write "state.json" '(:status "updating"))))))
       (should-error (org-wiki-qmd--search "query" 10))))))

(ert-deftest org-wiki-qmd-test-result-uri-boundaries ()
  (org-wiki-qmd-test--index
   (let* ((path (plist-get (car (plist-get (org-wiki-qmd--read "manifest.json") :nodes)) :path))
          (valid (concat "qmd://wiki/" path "?index=wiki-test")))
     (should (equal path (org-wiki-qmd--hit-path (list :file valid))))
     (dolist (file (list (concat "qmd://other/" path "?index=wiki-test")
                         (concat "qmd://wiki/../" path "?index=wiki-test")
                         (concat "qmd://wiki/" path "?index=foreign")
                         (concat "qmd://wiki/" path) "/tmp/foreign.md"))
       (should-not (org-wiki-qmd--hit-path (list :file file)))))))

(ert-deftest org-wiki-qmd-test-deduplicate-preserving-rank-and-k ()
  (org-wiki-qmd-test--index
   (let* ((nodes (plist-get (org-wiki-qmd--read "manifest.json") :nodes))
          (hits (mapcar (lambda (node) (list :file (concat "qmd://wiki/" (plist-get node :path)
                                                           "?index=wiki-test"))) (reverse nodes)))
          (org-wiki-qmd-test--output (json-serialize (vconcat (cons (car hits) hits)))))
     (should (equal (mapcar (lambda (node) (plist-get node :id))
                            (org-wiki-qmd--search "query" 10))
                    (mapcar (lambda (node) (plist-get node :id)) (reverse nodes))))
     (should (= 1 (length (org-wiki-qmd--search "query" 1)))))))

(ert-deftest org-wiki-qmd-test-lock-and-owner-isolation ()
  (org-wiki-qmd-test--index
   (org-wiki-qmd--lock
    (lambda () (should-error (org-wiki-qmd-sync)) (should-not (org-wiki-qmd--ready))))
   (let ((org-wiki-root (expand-file-name "different" base)))
     (should-error (org-wiki-qmd-sync))
     (should-error (org-wiki-qmd-setup)))
   (should (org-wiki-qmd--ready))))

(ert-deftest org-wiki-qmd-test-commit-marker-and-config-integrity ()
  (org-wiki-qmd-test--index
   (org-wiki-qmd--write "manifest.json" '(:generation "wrong"))
   (should-not (org-wiki-qmd--ready))
   (org-wiki-qmd-sync)
   (should (org-wiki-qmd--ready))
   (org-wiki-qmd--write "config/wiki-test.yml" '(:collections nil))
   (should-error (org-wiki-qmd-sync))
   (org-wiki-qmd-setup)
   (should-not (org-wiki-qmd--ready))
   (org-wiki-qmd-sync)
   (should (org-wiki-qmd--ready))))

(ert-deftest org-wiki-qmd-test-local-model-readiness ()
  (org-wiki-qmd-test--index
   (let ((org-wiki-qmd-search-mode 'vsearch))
     (should-error (org-wiki-qmd--ready)))
   (let* ((model (expand-file-name "model.gguf" base))
          (org-wiki-qmd-models (list :embed model :generate model)))
     (with-temp-file model (insert "fixture"))
     (org-wiki-qmd-embed)
     (let ((org-wiki-qmd-search-mode 'vsearch)) (should (org-wiki-qmd--ready)))
     (let ((org-wiki-qmd-search-mode 'query)) (should-error (org-wiki-qmd--ready)))
     (org-wiki-qmd-sync)
     (let ((org-wiki-qmd-search-mode 'vsearch)) (should-not (org-wiki-qmd--ready))))))

(ert-deftest org-wiki-qmd-test-vsearch-requires-generation-before-process ()
  (org-wiki-qmd-test--index
   (let* ((model (expand-file-name "embed.gguf" base))
          (org-wiki-qmd-models (list :embed model))
          (org-wiki-qmd-search-mode 'vsearch))
     (with-temp-file model (insert "fixture"))
     ;; Preparing embeddings needs no generation model, but searching does.
     (org-wiki-qmd-embed)
     (setq org-wiki-qmd-test--calls nil)
     (should (org-wiki--search "Parent"))
     (should-not org-wiki-qmd-test--calls)
     (should (string-match-p ":generate" org-wiki-qmd-last-error)))))

(ert-deftest org-wiki-qmd-test-rebuilds-vectors-after-model-replacement ()
  (org-wiki-qmd-test--index
   (let* ((model (expand-file-name "embed.gguf" base))
          (org-wiki-qmd-models (list :embed model))
          (run (symbol-function 'org-wiki-qmd--run))
          vectors)
     (with-temp-file model (insert "original weights"))
     ;; Model qmd's incremental cache: changing bytes at the same path does
     ;; not invalidate its existing vectors without an explicit rebuild.
     (cl-letf (((symbol-function 'org-wiki-qmd--run)
                (lambda (args timeout)
                  (when (and (equal (car args) "embed")
                             (or (not vectors) (member "--force" args)))
                    (setq vectors (with-temp-buffer
                                    (insert-file-contents model) (buffer-string))))
                  (funcall run args timeout))))
       (org-wiki-qmd-embed)
       (with-temp-file model (insert "replacement weights"))
       ;; Sync must not forget which model produced the existing vectors.
       (org-wiki-qmd-sync)
       (org-wiki-qmd-embed)
       (should (equal vectors "replacement weights"))
       (org-wiki-qmd-sync)
       (org-wiki-qmd-embed)
       (should-not (member "--force" (car org-wiki-qmd-test--calls)))))))

(ert-deftest org-wiki-qmd-test-rebuilds-after-interrupted-embedding ()
  (org-wiki-qmd-test--index
   (let* ((model (expand-file-name "embed.gguf" base))
          (org-wiki-qmd-models (list :embed model)))
     (with-temp-file model (insert "fixture"))
     (org-wiki-qmd-embed)
     (let ((org-wiki-qmd-test--fail "embed")) (should-error (org-wiki-qmd-embed)))
     (org-wiki-qmd-sync)
     (org-wiki-qmd-embed)
     (should (member "--force" (car org-wiki-qmd-test--calls))))))

(defun org-wiki-qmd-test--script (body)
  "Create an executable shell script containing BODY in the cache."
  (let ((file (org-wiki-qmd--path "fake-qmd")))
    (with-temp-file file (insert "#!/bin/sh\n" body "\n"))
    (set-file-modes file #o700)
    file))

(ert-deftest org-wiki-qmd-test-process-stdout-stderr-and-arguments ()
  (org-wiki-qmd-test--fixture
   (make-directory org-wiki-qmd-cache-directory)
   (let* ((org-wiki-qmd-program (org-wiki-qmd-test--script "printf '%s\\n' \"$@\"; printf 'log' >&2"))
          (output (org-wiki-qmd--run '("search" "--" "-quoted \"$hello\" 中文") 2)))
     (should (equal output "--index\nwiki-test\nsearch\n--\n-quoted \"$hello\" 中文\n"))
     (should-not (get-buffer " *org-wiki-qmd-out*")))))

(ert-deftest org-wiki-qmd-test-process-fail-timeout-limit-and-cleanup ()
  (org-wiki-qmd-test--fixture
   (make-directory org-wiki-qmd-cache-directory)
   (dolist (case '(("printf 'bad' >&2; exit 7" 2 4096)
                   ("sleep 10" 0.05 4096)
                   ("printf 'xxxxxxxxxxxxxxxxxxxxxxxx'" 2 8)))
     (let ((org-wiki-qmd-program (org-wiki-qmd-test--script (nth 0 case)))
           (org-wiki-qmd-output-limit (nth 2 case)))
       (should-error (org-wiki-qmd--run '("test") (nth 1 case)))
       (should-not (get-buffer " *org-wiki-qmd-out*"))
       (should-not (get-buffer " *org-wiki-qmd-err*"))))))

(ert-deftest org-wiki-qmd-test-process-quit-cleanup ()
  (org-wiki-qmd-test--fixture
   (make-directory org-wiki-qmd-cache-directory)
   (let ((org-wiki-qmd-program (org-wiki-qmd-test--script "sleep 10")))
     (cl-letf (((symbol-function 'accept-process-output) (lambda (&rest _) (signal 'quit nil))))
       (should (eq 'quit (condition-case nil (org-wiki-qmd--run '("test") 2) (quit 'quit)))))
     (should-not (get-process "org-wiki-qmd")))))

(ert-deftest org-wiki-qmd-test-orphan-keeps-maintenance-lock ()
  (dolist (ending '("sleep 1.2\nexit 7" "exit 7" "exit 0"))
    (org-wiki-qmd-test--fixture
     (make-directory org-wiki-qmd-cache-directory)
     (let ((org-wiki-qmd-program
            (org-wiki-qmd-test--script
             (concat "sleep 10 </dev/null >/dev/null 2>&1 &\nprintf '%s' $! > child.pid\n"
                     ending)))
           child)
       (unwind-protect
           (progn
             (should-error (org-wiki-qmd--lock
                            (lambda () (org-wiki-qmd--run '("update") 5))))
             (setq child (with-temp-buffer
                           (insert-file-contents (org-wiki-qmd--path "child.pid"))
                           (string-to-number (buffer-string))))
             (should (org-wiki-qmd--alive-p child))
             (should (file-exists-p (org-wiki-qmd--path "maintenance.lock")))
             (should-error (org-wiki-qmd--lock #'ignore))
             (signal-process child 'SIGKILL)
             (let ((deadline (+ (float-time) 2)))
               (while (and (org-wiki-qmd--alive-p child) (< (float-time) deadline))
                 (accept-process-output nil 0.01)))
             ;; Once all children have stopped, the same Emacs can retry.
             (org-wiki-qmd--lock #'ignore)
             (should-not (file-exists-p (org-wiki-qmd--path "maintenance.lock"))))
         (when child (ignore-errors (signal-process child 'SIGKILL))))))))

(ert-deftest org-wiki-qmd-test-three-entrypoints-and-disabled-prefix ()
  (require 'org-wiki-mcp)
  (require 'org-wiki-gptel)
  (require 'org-wiki-commands)
  (org-wiki-qmd-test--index
   (let* ((expected (org-wiki--search "keyword" 10))
          (mcp (json-parse-string (org-wiki-mcp--search-tool "keyword" "10")
                                  :array-type 'list :object-type 'plist))
          (gptel (json-parse-string (org-wiki-gptel--search "keyword" 10)
                                    :array-type 'list :object-type 'plist)))
     (should (equal expected mcp))
     (should (equal expected gptel)))
   (setq org-wiki-qmd-test--calls nil)
   (cl-letf (((symbol-function 'org-wiki--read) (lambda (&rest _) nil)))
     (org-wiki-search "Parent" t))
   (should-not org-wiki-qmd-test--calls)
   (let ((org-wiki-qmd-enabled nil))
     (org-wiki-mcp--search-tool "Parent" "10")
     (org-wiki-gptel--search "Parent" 10)
     (cl-letf (((symbol-function 'org-wiki--read) (lambda (&rest _) nil)))
       (org-wiki-search "Parent"))
     (should-not org-wiki-qmd-test--calls))))

(ert-deftest org-wiki-qmd-test-summary-cache-invalidated-by-edits ()
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Summary\nFirst.\n")
    (goto-char (point-min))
    (should (equal (org-wiki--extract-summary) "First."))
    (save-excursion (goto-char (point-max)) (insert "Second.\n"))
    (should (equal (org-wiki--extract-summary) "First.\nSecond."))
    (should (= (point) (point-min)))))

(ert-deftest org-wiki-qmd-test-code-text-is-inert ()
  (org-wiki-qmd-test--fixture
   (with-temp-file source
     (insert "* Literal\n:PROPERTIES:\n:ID: code\n:WIKI_KIND: Concept\n:END:\n#+begin_src org\n[[id:literal][Do not replace]]\n#+INCLUDE: \"do-not-open\"\n#+end_src\n"))
   (let* ((snapshot (org-wiki-qmd--snapshot (list (file-truename source))))
          (text (plist-get (car (plist-get snapshot :nodes)) :text)))
     (should (string-match-p (regexp-quote "[[id:literal][Do not replace]]") text))
     (should (string-match-p "do-not-open" text)))))

(ert-deftest org-wiki-qmd-test-partial-commit-recovery ()
  (org-wiki-qmd-test--index
   (let ((write (symbol-function 'org-wiki-qmd--write)))
     (dolist (phase '("manifest.json" "ready"))
       (cl-letf (((symbol-function 'org-wiki-qmd--write)
                  (lambda (name data)
                    (if (or (equal name phase)
                            (and (equal phase "ready") (equal name "state.json")
                                 (equal (plist-get data :status) "ready")))
                        (error "Injected commit interruption")
                      (funcall write name data)))))
         (should-error (org-wiki-qmd-sync)))
       (should-not (org-wiki-qmd--ready))
       (org-wiki-qmd-sync)
       (should (org-wiki-qmd--ready))))))

(ert-deftest org-wiki-qmd-test-stale-lock-and-foreign-lock ()
  (org-wiki-qmd-test--index
   (make-directory (org-wiki-qmd--path "maintenance.lock"))
   (org-wiki-qmd--write "maintenance.lock/owner.json"
                        (list :pid 99999999 :host "foreign" :children []))
   (should-error (org-wiki-qmd-sync))
   (org-wiki-qmd--write "maintenance.lock/owner.json"
                        (list :pid 99999999 :host (system-name) :children []))
   (org-wiki-qmd-sync)
   (should (org-wiki-qmd--ready))
   (should-not (file-exists-p (org-wiki-qmd--path "maintenance.claim")))))

(ert-deftest org-wiki-qmd-test-unconfigured-unready-and-missing-program ()
  (org-wiki-qmd-test--fixture
   (let ((org-wiki-qmd-collection nil)) (should-error (org-wiki-qmd-setup)))
   (should (org-wiki--search "Parent"))
   (make-directory org-wiki-qmd-cache-directory)
   (let ((org-wiki-qmd-program "/missing/org-wiki-qmd-executable"))
     (should-error (org-wiki-qmd--run '("--version") 1)))
   (should-not (get-buffer " *org-wiki-qmd-out*"))))

(ert-deftest org-wiki-qmd-test-status-pending-sync-without-processes ()
  (org-wiki-qmd-test--index
   (should-not (plist-get (org-wiki-qmd-status) :pending-sync))
   (with-temp-file source (insert org-wiki-qmd-test--source "Changed.\n"))
   (setq org-wiki-qmd-test--calls nil)
   (should (plist-get (org-wiki-qmd-status) :pending-sync))
   (should-not org-wiki-qmd-test--calls)))

(ert-deftest org-wiki-qmd-test-external-edit-preserving-mtime ()
  (org-wiki-qmd-test--index
   (let ((mtime (file-attribute-modification-time (file-attributes source)))
         (node (seq-find (lambda (entry) (equal (plist-get entry :id) "child"))
                         (plist-get (org-wiki-qmd--read "manifest.json") :nodes))))
     (with-temp-file source
       (insert (string-replace "Child secret" "Child public" org-wiki-qmd-test--source)))
     (set-file-times source mtime)
     (should-error (org-wiki-qmd--validate-node node)))))

(provide 'org-wiki-qmd-test)
;;; org-wiki-qmd-test.el ends here
