;;; org-wiki.el --- Org-native LLM Wiki (read-only spike) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@gnu.org>
;; Created: 14 May 2026
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6") (org-roam "2.2") (org-ql "0.7") (mcp-server-lib "0.4"))
;; Keywords: outlines hypermedia
;; URL: https://github.com/jwiegley/dot-emacs

;; This file is distributed under the BSD 3-clause license; see the
;; LICENSE.md file in this repository for the full text.

;;; Commentary:

;; This package is the *read-only spike* for the Org-native LLM Wiki design
;; specified in `~/src/dot-emacs/lisp/docs/org-llm-wiki.md'.  Its purpose is
;; not to be the final implementation but to empirically validate the
;; load-bearing assumptions of the design *before* the mutation tools are
;; built.  Specifically it answers:
;;
;;   - Does (property "WIKI_KIND") as an org-ql predicate work as the doc
;;     claims (matches any node with the property set)?
;;   - Does mcp-server-lib's handler-positional + keyword-properties
;;     registration signature work for multi-positional-arg defuns?
;;   - Does the `MCP Parameters:' docstring block actually get parsed into
;;     a JSON schema?
;;   - Does a `condition-case (error ...)' clause catch a
;;     `mcp-server-lib-tool-error' signal (the bug v2.2 was supposed to
;;     fix)?
;;   - What server-id should wiki tools use, given that `elisp-dev-mcp'
;;     registers under its own?
;;
;; Tools implemented (all read-only):
;;
;;   - org-wiki--search        — semantic search (uses org-ql-semantic if
;;                              available, otherwise falls back to text
;;                              match) scoped to nodes with :WIKI_KIND:.
;;   - org-wiki-read-node     — return full body text of a node by :ID:.
;;   - org-wiki-node-metadata — return the property drawer (minus the
;;                              hash property) as a plist.
;;   - org-wiki--backlinks     — return backlinks from org-roam for a node.
;;
;; Identity predicates:
;;
;;   - org-wiki-node-p     — t iff the entry at point has :WIKI_KIND:
;;                           set.  Identity is property-only (§2.1);
;;                           location is a placement convention.
;;   - org-wiki-writable-p — additionally requires the file to live
;;                           under `org-wiki-root' (the write-allowlist
;;                           boundary for the future mutation slice).
;;
;; Files and headings can each carry their own :WIKI_KIND: and canonical
;; :ID:.  A file ID without a file-level :WIKI_KIND: remains a read alias
;; for the first wiki heading, as used by older two-ID files.
;;
;; The read-only surface needs none of: file locking, write-ahead log,
;; recovery, hash discipline, sandboxing.  Those will be added in the
;; mutation slice once the read-only assumptions are verified.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'org-element)
(require 'seq)
(require 'subr-x)

;; org-ql is loaded on demand by the semantic backend.
(declare-function org-ql-select "org-ql")
(declare-function org-roam-backlinks-get "org-roam-mode")
(declare-function org-roam-node-from-id "org-roam-node")
;; cl-defstruct accessors: check-declare cannot resolve them, so only
;; verify the defining file exists (FILEONLY = t).
(declare-function org-roam-backlink-source-node "org-roam-mode" (backlink) t)
(declare-function org-roam-node-id "org-roam-node" (node) t)
(declare-function org-roam-node-title "org-roam-node" (node) t)
(declare-function org-roam-node-file "org-roam-node" (node) t)
(declare-function org-ql-semantic-files "ext:org-ql-semantic")
(declare-function org-ql-semantic--match-score "ext:org-ql-semantic")
(declare-function org-hash-property "ext:org-hash")
(declare-function org-roam-db-query "org-roam-db")
(declare-function org-wiki-qmd--search "org-wiki-qmd" (query k &optional select))
(defvar org-roam-db-location)

(defgroup org-wiki nil
  "Org-native LLM Wiki — read-only spike."
  :group 'org-roam
  :prefix "org-wiki-")

(defcustom org-wiki-root (expand-file-name "wiki/" (or (bound-and-true-p org-roam-directory)
                                                       "~/org/"))
  "Default directory for wiki discovery and the write boundary.
Read discovery can also include wiki nodes indexed elsewhere by org-roam."
  :type 'directory
  :group 'org-wiki)

(defconst org-wiki-memory-kinds '("道" "法" "术" "Memory")
  "Kinds for distilled memories and raw observations.")

(defun org-wiki--canonical-kind (kind)
  "Return the current wiki kind for the stored KIND."
  (if (member kind '("Comparison" "Question" "Index")) "relationship" kind))

(defcustom org-wiki-kinds
  (append '("Concept" "Entity" "Topic" "relationship" "Source-Record" "Frozen")
          (copy-sequence org-wiki-memory-kinds))
  "Permitted values for the `:WIKI_KIND:' property."
  :type '(repeat string)
  :group 'org-wiki)

(defcustom org-wiki-default-search-limit 10
  "Default `k' (max results) for `org-wiki--search'."
  :type 'integer
  :group 'org-wiki)

(defcustom org-wiki-search-backend 'auto
  "Search backend: auto, qmd, org-ql-semantic, or text.
Auto tries enabled qmd search, then semantic search, then literal search.
Explicit qmd falls back directly to literal search."
  :type '(choice (const auto) (const qmd) (const org-ql-semantic)
                 (const text))
  :group 'org-wiki)

(defcustom org-wiki-qmd-enabled nil
  "Whether searches may use the optional qmd backend.
Changing this option starts no processes and preserves existing indexes.
Explicit maintenance commands work even when search is disabled."
  :type 'boolean
  :group 'org-wiki)

(defvar org-wiki-qmd-last-error nil
  "Most recent qmd failure or reason for skipping qmd search.
This diagnostic is local to Emacs and is not part of tool results.")

(defcustom org-wiki-id-refresh-interval 300
  "Minimum seconds between cold-path `org-id-update-id-locations' calls.
The refresh rescans the whole known corpus (org-id unions the files
it is given with agenda files and previously known files), so an
agent retrying hallucinated IDs must not be able to trigger a full
rescan on every miss."
  :type 'integer
  :group 'org-wiki)

;;;; --- Identity predicate -----------------------------------------

(defun org-wiki--under-root-p (file)
  "Return t if FILE is under `org-wiki-root'."
  (and file
       (string-prefix-p (expand-file-name (file-name-as-directory org-wiki-root))
                        (expand-file-name file))))

;;;###autoload
(defun org-wiki-node-p (&optional pom)
  "Return t if the entry at POM is a wiki node.
POM is a point or marker, defaulting to point.

Identity is property-only per the architecture doc §2.1: a wiki node is
any Org entry that has a `:WIKI_KIND:' property.  The canonical
location `org-wiki-root' and the `:wiki:' filetag are placement
*conventions*, not part of identity — wiki nodes can drift outside the
canonical directory and remain valid for reads.  Write tools
additionally require `org-wiki-writable-p' to be non-nil before they
will mutate."
  (org-with-point-at (or pom (point))
    (and (derived-mode-p 'org-mode)
         (org-entry-get nil "WIKI_KIND"))))

;;;###autoload
(defun org-wiki-writable-p (&optional pom)
  "Return t if the entry at POM is a wiki node and lives in a writable location.

A node is writable iff it satisfies `org-wiki-node-p' AND its buffer file
is under `org-wiki-root'.  Write-side tools (in the future mutation
spike) gate on this; the read-only spike doesn't need it but exposes it
for callers."
  (org-with-point-at (or pom (point))
    (and (org-wiki-node-p)
         (org-wiki--under-root-p (buffer-file-name)))))

;;;; --- Internal helpers -------------------------------------------

(defun org-wiki--all-files ()
  "Return a list of absolute paths of all .org files under `org-wiki-root'."
  (when (file-directory-p org-wiki-root)
    (directory-files-recursively org-wiki-root "\\.org\\'")))

(defun org-wiki--roam-db-ready-p ()
  "Return non-nil when Org-roam can query an existing database."
  (and (fboundp 'org-roam-db-query)
       (bound-and-true-p org-roam-db-location)
       (file-regular-p org-roam-db-location)))

(defun org-wiki--roam-wiki-files ()
  "Return corpus files holding wiki nodes, per the org-roam DB.
Identity is property-only (architecture doc §2.1): wiki nodes that
have drifted outside `org-wiki-root' are still wiki nodes, and the
roam DB is how reads find them.  Returns nil when org-roam or its
database is unavailable.  The full-table scan is acceptable at
personal scale; revisit with a cached view if the corpus grows."
  (when (org-wiki--roam-db-ready-p)
    (ignore-errors
      (let (files)
        (pcase-dolist (`(,file ,properties)
                       (org-roam-db-query
                        [:select :distinct [file properties] :from nodes]))
          (when (assoc "WIKI_KIND" properties)
            (push file files)))
        (nreverse files)))))

(defun org-wiki--memory-relation-ids ()
  "Return Org IDs from the managed Relations list in this memory file."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^\\* Relations$" nil t)
      (let ((end (save-excursion (outline-next-heading) (point)))
            ids)
        (while (re-search-forward (concat "^- " org-link-bracket-re "$") end t)
          (let ((path (org-link-unescape (match-string-no-properties 1))))
            (when (string-prefix-p "id:" path)
              (push (substring path 3) ids))))
        (nreverse ids)))))

(defun org-wiki--candidate-files ()
  "Return all files that may contain wiki nodes.
The wiki tree is always included; when the org-roam DB is available,
files elsewhere in the corpus whose nodes carry `:WIKI_KIND:' are
included too, so that search honors property-only identity."
  (delete-dups (nconc (org-wiki--all-files) (org-wiki--roam-wiki-files))))

(defvar org-wiki--id-last-refresh 0
  "`float-time' of the last cold-path org-id locations refresh.")

(defun org-wiki--locate-id (id)
  "Return the file containing ID per `org-id-locations', or nil.
On a miss, refresh the locations table at most once per
`org-wiki-id-refresh-interval' seconds and retry."
  (or (and (hash-table-p org-id-locations)
           (gethash id org-id-locations))
      (when (> (- (float-time) org-wiki--id-last-refresh)
               org-wiki-id-refresh-interval)
        (setq org-wiki--id-last-refresh (float-time))
        (org-id-update-id-locations (org-wiki--candidate-files))
        (and (hash-table-p org-id-locations)
             (gethash id org-id-locations)))))

(defun org-wiki--node-buffer (file)
  "Return a buffer visiting FILE, reusing any live buffer.
Fresh buffers are fully initialized by `find-file-noselect' and left
live, so later visits (and `org-wiki--visit') can reuse them safely."
  (or (get-file-buffer file)
      (find-buffer-visiting file)
      (find-file-noselect file)))

(defun org-wiki--file-node-p ()
  "Return the file's wiki kind at the start of a widened buffer."
  (and (not (org-at-heading-p)) (org-entry-get nil "WIKI_KIND")))

(defvar-local org-wiki--node-positions-cache nil
  "Positions of wiki nodes at the last checked buffer modification tick.")

(defun org-wiki--node-positions ()
  "Return file and heading node positions in the current widened buffer."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eq tick (car org-wiki--node-positions-cache))
      (save-excursion
        (goto-char (point-min))
        (let ((root (when (org-wiki--file-node-p) (list (point))))
              (headings (org-element-map (org-element-parse-buffer 'headline) 'headline
                          (lambda (heading)
                            (let ((pos (org-element-property :begin heading)))
                              (when (org-entry-get pos "WIKI_KIND") pos))))))
          (setq org-wiki--node-positions-cache (cons tick (append root headings))))))
    (cdr org-wiki--node-positions-cache)))

(defun org-wiki--file-title (&optional file)
  "Return the preamble's TITLE or the basename of FILE or the visited file."
  (save-excursion
    (save-restriction
      (goto-char (point-min))
      (outline-next-heading)
      (narrow-to-region (point-min) (point))
      (or (org-element-map (org-element-parse-buffer 'element) 'keyword
            (lambda (keyword)
              (when (equal (org-element-property :key keyword) "TITLE")
                (let ((title (string-trim (org-element-property :value keyword))))
                  (unless (string-empty-p title) title))))
            nil t)
          (file-name-base (or file buffer-file-name (buffer-name)))))))

(defun org-wiki--goto-owner ()
  "Move to the nearest enclosing wiki node and return its kind, if any."
  (org-back-to-heading-or-point-min t)
  (let ((kind (org-entry-get nil "WIKI_KIND")))
    (while (and (not kind) (org-up-heading-safe))
      (setq kind (org-entry-get nil "WIKI_KIND")))
    (or kind (progn (goto-char (point-min)) (org-wiki--file-node-p)))))

(defvar-local org-wiki--last-id-location nil
  "Last successful ID lookup, keyed by ID and buffer modification tick.")

(defun org-wiki--goto-id (id)
  "Move to the entry for ID in a widened buffer and return its canonical ID.
A file ID with no file-level WIKI_KIND redirects to its first wiki heading.
Signal `org-wiki-error' for a stale location or an alias with no wiki node."
  ;; Tool reads resolve the canonical ID and then immediately read it.
  ;; Reuse that lookup until an edit can change the drawer or its position.
  (let* ((tick (buffer-chars-modified-tick))
         (pos (if (and (eq tick (car org-wiki--last-id-location))
                       (equal id (nth 1 org-wiki--last-id-location)))
                  (nth 2 org-wiki--last-id-location)
                (org-find-entry-with-id id))))
    (unless pos (signal 'org-wiki-error (list :id_not_in_file id)))
    (setq org-wiki--last-id-location (list tick id pos))
    (goto-char pos)
    (if (or (org-at-heading-p) (org-wiki--file-node-p))
        id
      (let ((heading (car (org-wiki--node-positions))))
        (unless heading (signal 'org-wiki-error (list :not_a_wiki_node id)))
        (goto-char heading)
        (or (org-entry-get nil "ID") id)))))

(defun org-wiki--resolve-id (id)
  "Resolve a known file alias for backlinks, otherwise return ID.
Only consult warm ID locations so external linkers need no corpus scan."
  (let ((file (and (hash-table-p org-id-locations)
                   (gethash id org-id-locations))))
    (or (and file (file-exists-p file)
             (with-current-buffer (org-wiki--node-buffer file)
               (org-with-wide-buffer
                (condition-case nil (org-wiki--goto-id id)
                  (org-wiki-error nil)))))
        id)))

(defun org-wiki--hash-property-name ()
  "Return the name of the hash property `org-hash' writes, if available.
Returns nil when `org-hash' isn't loaded — in which case the read-only
spike just won't strip a hash from `node-metadata' output."
  (when (fboundp 'org-hash-property)
    (org-hash-property)))

(defvar-local org-wiki--node-data-cache nil
  "Read results at node positions for the current buffer modification tick.")

(defun org-wiki--cached-node-data (reader &optional context)
  "Call READER at the current node, caching by buffer state and CONTEXT."
  (let ((tick (buffer-chars-modified-tick))
        (key (list reader (point) (point-min) (point-max) buffer-file-name context)))
    (unless (eq tick (car org-wiki--node-data-cache))
      (setq org-wiki--node-data-cache (cons tick (make-hash-table :test #'equal))))
    (let ((table (cdr org-wiki--node-data-cache)))
      (or (gethash key table)
          (puthash key (funcall reader) table)))))

(defun org-wiki--summarize-entry ()
  "Build the summary plist for the node at point."
  (list :id (org-entry-get nil "ID")
        :title (if (org-at-heading-p) (org-entry-get nil "ITEM")
                 (org-wiki--file-title))
        :kind (org-wiki--canonical-kind (org-entry-get nil "WIKI_KIND"))
        :file buffer-file-name
        :summary (org-wiki--extract-summary)))

(defun org-wiki--node-at-point-summary ()
  "Return :id, :title, :kind, :file and :summary for the node at point."
  (org-wiki--cached-node-data #'org-wiki--summarize-entry))

(defun org-wiki--extract-summary ()
  "Return the first ordinary, direct Summary child's body at point.
Respect the wiki node's level and exclude nested wiki subtrees.
Return an empty string when no such child exists."
  (save-excursion
    (save-restriction
      (when (org-at-heading-p) (org-narrow-to-subtree))
      (let ((level (1+ (org-outline-level))))
        (or (org-element-map (org-element-parse-buffer 'headline) 'headline
              (lambda (heading)
                (when (and (= level (org-element-property :level heading))
                           (equal "Summary" (org-element-property :raw-value heading))
                           (not (org-entry-get
                                 (org-element-property :begin heading) "WIKI_KIND")))
                  (string-trim
                   (org-wiki--owned-region-text
                    (save-excursion
                      (goto-char (org-element-property :begin heading))
                      (forward-line) (point))
                    (org-element-property :end heading)))))
              nil t)
            "")))))

(defun org-wiki--owned-region-text (begin end)
  "Return text from BEGIN to END, excluding any wiki subtrees in it.
The region must begin at a line boundary in an Org buffer."
  (save-excursion
    (save-restriction
      (narrow-to-region begin end)
      (let ((cursor begin) pieces)
        (org-element-map (org-element-parse-buffer 'headline) 'headline
          (lambda (heading)
            (let ((start (org-element-property :begin heading)))
              (when (and (>= start cursor)
                         (org-entry-get start "WIKI_KIND"))
                (push (buffer-substring-no-properties cursor start) pieces)
                (setq cursor (org-element-property :end heading))))))
        (push (buffer-substring-no-properties cursor end) pieces)
        (apply #'concat (nreverse pieces))))))

(defun org-wiki--owned-body ()
  "Return this node's body text excluding nested wiki nodes."
  (save-excursion
    (if (org-at-heading-p)
        (org-wiki--owned-region-text
         (save-excursion (forward-line) (point))
         (progn (org-end-of-subtree t t) (point)))
      (org-wiki--owned-region-text (point-min) (point-max)))))

;;;; --- Discovery tools --------------------------------------------

(defvar org-wiki--semantic-require-failed nil
  "Non-nil after a soft load of org-ql-semantic has failed.
Set whether the library is absent from `load-path' or present but
broken (its load signaled an error).  Caps the failed library probe
at once per session: search sits on hot paths (every MCP call, the
benchmark and fuzz harnesses), and a failing library would otherwise
re-scan `load-path' — or re-attempt a full load — on every query.")

(defun org-wiki--semantic-available-p ()
  "Return non-nil when the org-ql-semantic backend can be used.
Loads the library on first use when it is present on `load-path' but
not yet loaded — a deferred `use-package' configuration still applies
through `eval-after-load'.  Any failed load — the library absent, or
present but signaling during load — is remembered and not repeated,
though a later in-session load is still picked up via `fboundp'."
  (cond ((fboundp 'org-ql-semantic-files) t)
        (org-wiki--semantic-require-failed nil)
        ;; NOERROR only covers a missing file; a present-but-broken
        ;; library signals out of `require' and must be caught here,
        ;; or it escapes to the caller and the memo is never set.
        ((condition-case nil
             (require 'org-ql-semantic nil t)
           (error nil))
         t)
        (t (setq org-wiki--semantic-require-failed t)
           nil)))

(defun org-wiki--try-qmd (query k &optional select)
  "Return up to K qmd hits for QUERY, optionally processed by SELECT.
Honor the Emacs backend settings and record qmd errors for diagnostics."
  (when (and (not (string-empty-p query))
             (memq org-wiki-search-backend '(auto qmd)))
    (if (not org-wiki-qmd-enabled)
        (progn (setq org-wiki-qmd-last-error "Search disabled") nil)
      (condition-case err
          (progn (require 'org-wiki-qmd)
                 (org-wiki-qmd--search query k select))
        (error (setq org-wiki-qmd-last-error (error-message-string err)) nil)))))

(defun org-wiki--search (query &optional k)
  "Search wiki nodes for QUERY, returning up to K (default 10) plists.
Each result has keys :id :title :kind :file :summary.

Use `org-wiki-search-backend' and `org-wiki-qmd-enabled' to select
backends.  Errors and empty results fall through to the next backend.
An empty QUERY uses literal discovery.  User quits always propagate."
  (let* ((k (or k org-wiki-default-search-limit))
         (files (org-wiki--candidate-files))
         (qmd (org-wiki--try-qmd query k))
         (semantic
          (condition-case nil
              (when (and (not qmd) (not (string-empty-p query))
                         (memq org-wiki-search-backend '(auto org-ql-semantic))
                         (org-wiki--semantic-available-p))
                (org-wiki--semantic-search query files))
            ;; Degraded mode: backend down or misconfigured.
            (error nil))))
    ;; An empty semantic result (no error signaled) also falls through
    ;; to the literal fallback: a paraphrase the embedding misses must
    ;; never beat a query that literal matching would have answered.
    (seq-take (or qmd semantic (org-wiki--text-search query files)) k)))

(defun org-wiki--semantic-search (query files)
  "Return wiki-node summaries for QUERY from FILES, best match first.
Each heading hit surfaces the closest enclosing wiki heading or file.
Each node is ranked by its best-matching heading's score.  The strongest
matches are routinely on Summary/Definition subheadings, which carry
no `:WIKI_KIND:' of their own."
  (require 'org-ql)
  (let ((wiki-set (make-hash-table :test #'equal)))
    ;; Key the candidate set by truename: FILES are discovered through
    ;; `org-wiki-root', which may reach the corpus through symlinks,
    ;; while the backend returns fully resolved paths.  Without
    ;; normalizing both sides the intersection comes back empty.
    (dolist (file files)
      (puthash (file-truename file) t wiki-set))
    ;; Filter the similarity-ordered list against the wiki set rather
    ;; than intersecting the other way around: `cl-intersection' does
    ;; not preserve order, and the ranking is the point.
    (let ((candidates (seq-filter (lambda (file)
                                    (gethash (file-truename file) wiki-set))
                                  (org-ql-semantic-files query))))
      (when candidates
        (let ((scored
               (delq nil
                     (org-ql-select candidates `(semantic ,query)
                                    :action
                                    (lambda ()
                                      (let ((score (or (org-ql-semantic--match-score query)
                                                       0.0)))
                                        (save-excursion
                                          (when (org-wiki--goto-owner)
                                            (cons score
                                                  (org-wiki--node-at-point-summary))))))))))
          ;; Org-ql iterates headings.  A backend that indexed the file ID
          ;; can also score the preamble, including a file with no headings.
          (dolist (file candidates)
            (with-current-buffer (org-wiki--node-buffer file)
              (org-with-wide-buffer
               (goto-char (point-min))
               (when (org-wiki--file-node-p)
                 (when-let* ((score (ignore-errors (org-ql-semantic--match-score query))))
                   (push (cons score (org-wiki--node-at-point-summary)) scored))))))
          ;; Rank the plists ourselves: `org-ql-select' applies :sort
          ;; to the ACTION results, and org-ql-semantic's comparator
          ;; expects org elements, so handing it summary plists dies
          ;; with wrong-type-argument.  Dedupe by node id keeping the
          ;; best score per node, then sort descending.
          (let ((best (make-hash-table :test #'equal)))
            (dolist (sr scored)
              (let* ((id (plist-get (cdr sr) :id))
                     (prev (gethash id best)))
                (when (or (null prev) (> (car sr) (car prev)))
                  (puthash id sr best))))
            (let (out)
              (maphash (lambda (_id sr) (push sr out)) best)
              (mapcar #'cdr
                      (sort out (lambda (a b) (> (car a) (car b))))))))))))

(defun org-wiki--matches-text-p (query)
  "Return non-nil if the node at point matches literal QUERY."
  (let ((case-fold-search t))
    (if (org-at-heading-p)
        ;; Match the heading and its entry text, as in org-ql's regexp predicate.
        (save-excursion
          (search-forward query (save-excursion (outline-next-heading) (point)) t))
      (let ((pattern (regexp-quote query)))
        (or (string-match-p pattern (org-wiki--file-title))
            (string-match-p pattern (org-wiki--owned-body)))))))

(defun org-wiki--select-nodes (files action &optional query)
  "Call ACTION at wiki nodes in FILES, optionally matching literal QUERY."
  (let (results)
    (dolist (file files)
      (when-let* ((buffer (or (get-file-buffer file)
                              (and (file-readable-p file) (org-wiki--node-buffer file)))))
        (with-current-buffer buffer
          (org-with-wide-buffer
           (dolist (pos (org-wiki--node-positions))
             (goto-char pos)
             (when (or (not query) (string-empty-p query) (org-wiki--matches-text-p query))
               (push (funcall action) results)))))))
    (nreverse results)))

(defun org-wiki--text-search (query files)
  "Return wiki-node summaries matching QUERY literally in FILES."
  (org-wiki--select-nodes files #'org-wiki--node-at-point-summary query))

;;;###autoload
(defun org-wiki-canonical-id (id)
  "Return the canonical file or heading ID for a wiki node.
A file ID without its own WIKI_KIND aliases the first wiki heading.
Signal `org-wiki-error' for an unknown ID, stale location or invalid alias."
  (let ((file (org-wiki--locate-id id)))
    (unless file
      (signal 'org-wiki-error (list :unknown_id id)))
    (with-current-buffer (org-wiki--node-buffer file)
      (org-with-wide-buffer
       (org-wiki--goto-id id)))))

(defun org-wiki--read-bounds ()
  "Return the validated file or subtree bounds at point."
  (when (org-wiki-node-p)
    (save-restriction
      (when (org-at-heading-p) (org-narrow-to-subtree))
      (cons (point-min) (point-max)))))

;;;###autoload
(defun org-wiki-read-node (id)
  "Return the full body of the wiki node with ID as a plain-text string.
The returned text includes the property drawer and all child headings.
File nodes return the whole file.  For a file ID used as a heading alias,
see `org-wiki-canonical-id'.  Signal `org-wiki-error' for unknown nodes."
  (let ((file (org-wiki--locate-id id)))
    (unless file
      (signal 'org-wiki-error (list :unknown_id id)))
    (with-current-buffer (org-wiki--node-buffer file)
      (org-with-wide-buffer
       (org-wiki--goto-id id)
       (let ((bounds (org-wiki--cached-node-data #'org-wiki--read-bounds)))
         (unless bounds (signal 'org-wiki-error (list :not_a_wiki_node id)))
         (buffer-substring-no-properties (car bounds) (cdr bounds)))))))

(defun org-wiki--entry-metadata ()
  "Collect standard properties at point, excluding integrity hashes."
  (cl-loop for (key . value) in (org-entry-properties nil 'standard)
           unless (string-prefix-p "HASH_" key t)
           append (list (intern (concat ":" (downcase key)))
                        (if (equal key "WIKI_KIND") (org-wiki--canonical-kind value) value))))

;;;###autoload
(defun org-wiki-node-metadata (id)
  "Return a plist of the property drawer of the wiki node with ID.
ID may be a file ID, heading ID or file alias (see `org-wiki-canonical-id').
The :id entry carries the canonical ID.  Hash properties whose names
start with \"HASH_\" are omitted."
  (let ((file (org-wiki--locate-id id)))
    (unless file
      (signal 'org-wiki-error (list :unknown_id id)))
    (with-current-buffer (org-wiki--node-buffer file)
      (org-with-wide-buffer
       (org-wiki--goto-id id)
       (copy-sequence
        (org-wiki--cached-node-data
         #'org-wiki--entry-metadata
         ;; CATEGORY can also be supplied by Org outside the drawer.
         (org-get-category)))))))

(defun org-wiki--backlinks (id)
  "Return a list of plists describing backlinks to the wiki node with ID.
Each plist has keys :from-id, :from-title and :from-file, so callers
can visit the linking node without consulting the org-id locations
table (linkers may live outside the wiki tree).

ID is first normalized with `org-wiki--resolve-id': nothing links to
the lint-mandated file-level alias, so querying it verbatim would
return a misleading empty list instead of the node's real backlinks.

Uses `org-roam-backlinks-get' when `org-roam' is loaded; otherwise
returns nil and logs a message."
  (cond
   ((not (fboundp 'org-roam-node-from-id))
    (message "org-wiki--backlinks: org-roam not loaded; returning nil")
    nil)
   (t
    (let* ((node (org-roam-node-from-id (org-wiki--resolve-id id)))
           (backlinks (and node (org-roam-backlinks-get node))))
      (mapcar (lambda (bl)
                (let ((src (org-roam-backlink-source-node bl)))
                  (list :from-id    (org-roam-node-id src)
                        :from-title (org-roam-node-title src)
                        :from-file  (org-roam-node-file src))))
              backlinks)))))

;;;; --- Error type -------------------------------------------------

(define-error 'org-wiki-error "Wiki tool error")

(provide 'org-wiki)
;;; org-wiki.el ends here
