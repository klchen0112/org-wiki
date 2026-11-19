;;; qmd-integration.el --- Opt-in real qmd contract checks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;;; Commentary:

;; Run make test-qmd-integration with qmd 2.8.3 on PATH.  No models or
;; network are needed.  The semantic target additionally requires local
;; GGUF paths in ORG_WIKI_QMD_EMBED_MODEL, ORG_WIKI_QMD_GENERATE_MODEL,
;; and ORG_WIKI_QMD_RERANK_MODEL.  User indexes/configs are never used.

;;; Code:

(require 'org-wiki-qmd-test)
(require 'org-wiki-mcp)
(require 'org-wiki-gptel)
(require 'org-wiki-commands)

(org-wiki-qmd-test--fixture
 (let ((org-wiki-qmd-search-timeout 120)
       (org-wiki-qmd-maintenance-timeout 1800))
   (with-temp-file source
     (insert ":PROPERTIES:\n:ID: file-root\n:WIKI_KIND: Topic\n:END:\n"
             (string-replace "Parent summary." "Parent summary. 内容寻址使用哈希。"
                             org-wiki-qmd-test--source)))
   (org-wiki-qmd-setup)
   (should-not org-wiki-qmd-test--calls)
   (org-wiki-qmd-sync)
   (should (org-wiki-qmd--ready))
   (let ((hits (org-wiki-qmd--search "Outside" 10)))
     (should (equal (mapcar (lambda (n) (plist-get n :id)) hits) '("file-root")))
     (should (equal (plist-get (car hits) :title) "Mixed file"))
     (should (string-prefix-p ":PROPERTIES:" (org-wiki-read-node "file-root"))))
   (should (equal '("parent")
                  (mapcar (lambda (node) (plist-get node :id))
                          (org-wiki-qmd--search "内容寻址" 10))))
   (let* ((query "Parent")
          (nodes (org-wiki--search query 10))
          (ids (mapcar (lambda (node) (plist-get node :id)) nodes))
          (mcp (json-parse-string (org-wiki-mcp--search-tool query 10)
                                  :object-type 'plist :array-type 'list))
          (gptel (json-parse-string (org-wiki-gptel--search query 10)
                                    :object-type 'plist :array-type 'list)))
     (should (equal ids '("parent")))
     (should (equal ids (mapcar (lambda (node) (plist-get node :id)) mcp)))
     (should (equal ids (mapcar (lambda (node) (plist-get node :id)) gptel)))
     (should (equal "parent" (org-wiki-canonical-id (car ids))))
     (should (string-match-p "Parent summary" (org-wiki-read-node (car ids))))
     (save-window-excursion
       (cl-letf (((symbol-function 'org-wiki--read) (lambda (_prompt candidates) (car candidates))))
         (org-wiki-search query)
         (should (equal "parent" (org-entry-get nil "ID"))))))
   ;; Capture the actual version-specific JSON as a reusable contract artifact.
   (let ((json (org-wiki-qmd--run
                '("search" "--format" "json" "-c" "wiki" "-n" "10" "--" "secret") 10)))
     (should (= 1 (length (json-parse-string json))))
     (when-let* ((output (getenv "ORG_WIKI_QMD_FIXTURE")))
       (write-region json nil output nil 'silent)))
   (should (equal "[]" (string-trim (org-wiki-qmd--run
                                     '("search" "--format" "json" "-c" "wiki" "--" "unfindablexyz") 10))))
   (should (stringp (org-wiki-qmd--run
                     '("search" "--format" "json" "-c" "wiki" "--" "-Parent \"$literal\"") 10)))
   (clrhash org-id-locations)
   (should (org-wiki--search "Child" 10))
   (should (string-match-p "Child secret" (org-wiki-read-node "child")))
   ;; A fresh Emacs must reject every incomplete commit point.  This also
   ;; proves readiness isn't kept only in the maintainer's process memory.
   (let ((state (org-wiki-qmd--read "state.json")))
     (dolist (broken (list '(:status "updating")
                           (plist-put (copy-sequence state) :manifest "wrong")
                           (plist-put (copy-sequence state) :generation "wrong")))
       (org-wiki-qmd--write "state.json" broken)
       (let ((form `(progn
                      (setq org-wiki-root ,org-wiki-root
                            org-wiki-qmd-cache-directory ,org-wiki-qmd-cache-directory
                            org-wiki-qmd-collection "wiki" org-wiki-qmd-index-name "wiki-test"
                            org-wiki-qmd-discovery-scope 'root-only)
                      (kill-emacs (if (org-wiki-qmd--ready) 1 0)))))
         (should (zerop (call-process (expand-file-name invocation-name invocation-directory)
                                      nil nil nil "-Q" "--batch" "-L" default-directory
                                      "-l" "org-wiki-qmd.el" "--eval" (prin1-to-string form))))))
     (org-wiki-qmd-sync))
   (when (getenv "ORG_WIKI_QMD_SEMANTIC")
     (setq org-wiki-qmd-models
           (list :embed (getenv "ORG_WIKI_QMD_EMBED_MODEL")
                 :generate (getenv "ORG_WIKI_QMD_GENERATE_MODEL")
                 :rerank (getenv "ORG_WIKI_QMD_RERANK_MODEL")))
     (org-wiki-qmd--require-models 'query)
     (org-wiki-qmd-embed)
     (dolist (mode '(vsearch query))
       (let ((org-wiki-qmd-search-mode mode))
         (should (seq-find (lambda (node) (equal (plist-get node :id) "child"))
                           (org-wiki-qmd--search "What confidential words does the child contain?" 10))))))
   (let ((org-wiki-qmd-enabled nil))
     (cl-letf (((symbol-function 'org-wiki-qmd--run) (lambda (&rest _) (error "Disabled qmd called"))))
       (should (org-wiki--search "Parent"))
       (should (org-wiki-qmd-status))))
   (kill-buffer (get-file-buffer source))
   (delete-file source)
   (org-wiki-qmd-sync)
   (should-not (org-wiki-qmd--search "Child" 10))
   (princ "qmd integration: isolated setup, sync, search, interfaces, recovery and deletion passed\n")))

;;; qmd-integration.el ends here
