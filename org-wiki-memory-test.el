;;; org-wiki-memory-test.el --- Agent memory regression tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise project scoping and mutation semantics without the user corpus.

;;; Code:
(require 'ert)
(require 'org-wiki-memory)

(ert-deftest org-wiki-memory-lifecycle ()
  (let* ((org-wiki-root (make-temp-file "memory-test" t))
         (org-id-locations (make-hash-table :test #'equal))
         (org-id-locations-file (expand-file-name ".ids" org-wiki-root))
         (ctx '((project . "A") (host . "pi") (session . "1") (request . "a")))
         (other (cons '(project . "B") ctx))
         (args '((category . "decision") (title . "项目验收")
                 (summary . "使用 make check 验收") (body . "Run make check."))))
    (unwind-protect
        (let* ((row (org-wiki-memory--call "remember" ctx args))
               (id (plist-get row :id))
               (key (list (cons 'id id)))
               (query '((query . "项目如何验收？")))
               (change (append key (list (cons 'expected_revision (plist-get row :revision)))
                               (cons '(summary . "使用新的测试") args))))
          (should (equal row (org-wiki-memory--call "remember" ctx args)))
          (should (equal row (org-wiki-memory--call "read" ctx key)))
          (should (= 1 (length (org-wiki-memory--call "search" ctx query))))
          (should (= 0 (length (org-wiki-memory--call "search" other query))))
          (should-error (org-wiki-memory--call "read" other key) :type 'org-wiki-error)
          (let* ((updated (org-wiki-memory--call "update" ctx change))
                 (forget (append key (list (cons 'expected_revision (plist-get updated :revision))))))
            (should (equal "使用新的测试" (plist-get updated :summary)))
            (should-error (org-wiki-memory--call "update" ctx (cons '(body . "stale") change))
                          :type 'org-wiki-error)
            (should (plist-get (org-wiki-memory--call "forget" ctx forget) :forgotten))
            (should (plist-get (org-wiki-memory--call "forget" ctx forget) :forgotten))
            (should-error (org-wiki-memory--call "read" ctx key) :type 'org-wiki-error))
          (org-wiki-memory--call "remember" (cons '(request . "b") ctx)
                                 (cons '(scope . "personal") args))
          (should (= 1 (length (org-wiki-memory--call "search" other query)))))
      (delete-directory org-wiki-root t))))

(ert-deftest org-wiki-memory-guards ()
  (let* ((org-wiki-root (make-temp-file "memory-guard" t))
         (ctx '((project . "A") (session . "1") (host . "pi") (request . "save")))
         (org-id-locations (make-hash-table :test #'equal))
         (args '((title . "Test") (summary . "test") (body . "original") (category . "fact")))
         (record (org-wiki-memory--call "remember" ctx args))
         (id (plist-get record :id))
         (file (gethash id org-id-locations))
         (buffer (find-file-noselect file))
         (edit (append (list (cons 'id id) (cons 'expected_revision (plist-get record :revision))) args)))
    (unwind-protect
        (progn
          (with-current-buffer buffer (goto-char (point-max)) (insert "Human edit"))
          (should-error (org-wiki-memory--call "update" ctx edit) :type 'org-wiki-error)
          (with-current-buffer buffer (save-buffer))
          (should-error (org-wiki-memory--call "update" ctx edit) :type 'org-wiki-error)
          (should-error (org-wiki-memory--call "read" ctx '((id . "../other.org"))) :type 'org-wiki-error)
          (make-symbolic-link file (expand-file-name "link.org" (file-name-directory file)))
          (should-error (org-wiki-memory--call "search" ctx '((query . "test"))) :type 'org-wiki-error)
          (should-error (org-wiki-memory--call "remember" ctx (cons '(scope . "all") args))
                        :type 'org-wiki-error))
      (kill-buffer buffer)
      (delete-directory org-wiki-root t))))

(provide 'org-wiki-memory-test)
;;; org-wiki-memory-test.el ends here
