;;; org-table-highlight.el --- Highlight Org table columns and rows -*- lexical-binding: t; -*-

;; Author: Lei Zhe
;; URL: https://github.com/llcc/org-table-highlight
;; Version: 0.6
;; Package-Requires: ((emacs "27.1"))
;; Keywords: org-table, convenience

;; This file is not part of GNU Emacs.

;; This package is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides utilities to highlight columns and rows in Org-mode tables.
;; It supports cycling through color palettes, clearing highlights, and working
;; with both column and row overlays.

;;; Code:

(require 'org-element)
(require 'org-table)
(require 'cl-lib)

(defgroup org-table-highlight nil
  "Highlight columns and rows in Org tables."
  :group 'org)

(defcustom org-table-highlight-color-palette
  '("#FFE4B5" "#C1FFC1" "#B0E0E6" "#FFB6C1" "#D8BFD8" "#F4A460" "#ADD8E6")
  "List of pastel colors used to highlight Org table columns and rows."
  :type '(repeat color)
  :group 'org-table-highlight)

(defvar org-table-highlight--metadata nil
  "Global metadata for Org table highlights across buffers.

This variable holds persistent information about highlighted rows and
columns in Org-mode tables, so highlights can be restored after buffer
reloads or Emacs restarts.

Structure:

  ((BUFFER-NAME
     (OTHM-TABLE ...)
   )
   ...)

Where:

- BUFFER-NAME is a string.
- Each OTHM-TABLE is a struct of type
  `org-table-highlight--metadata-table', describing highlight state for
  a specific Org table in that buffer.

Each `org-table-highlight--metadata-table' contains:

  - :context — an `org-table-highlight--metadata-context' struct that
    uniquely identifies the table:
      - :name (string or nil): the #+NAME: of the table if available.
      - :before-string: string content before the table begin.
      - :after-string: string content after the table end.

  - :col-highlights — a list of highlighted columns:
      ((COLUMN-INDEX :color COLOR) ...), where:
        - COLUMN-INDEX is an integer (1-based)
        - COLOR is a color string like \"#FFB6C1\"

  - `:row-highlights` — a list of highlighted rows:
      ((ROW-INDEX :color COLOR) ...), where:
        - ROW-INDEX is an integer (1-based)
        - COLOR is a string like \"#ADD8E6\"

Example:

  ((\"notes.org\"
     (#s(org-table-highlight--metadata-table
         :context #s(org-table-highlight--metadata-context
                    :name \"my-table\"
                    :before-string \"Text before the table\"
                    :after-string \"Text after the table\")
         :col-highlights ((2 :color \"#FFB6C1\") (3 :color \"#D8BFD8\"))
         :row-highlights ((1 :color \"#ADD8E6\") (4 :color \"#FFE4B5\")))))
   (\"tasks.org\" ...)
   ...)

This variable is updated when:
- Applying or removing column/row highlights
- Modifying table structure (inserting/deleting/moving rows/columns)
- Collecting metadata on buffer kill

It is saved to disk using `org-table-highlight-save-metadata`
and restored using `org-table-highlight-load-metadata`.")

(cl-defstruct org-table-highlight--metadata-context
  "Represents the context of an Org table within a buffer.
Includes identifying metadata such as a name, and text that occurs
before or after the table to help locate it uniquely."
  name            ; Unique name for the table
  before-string   ; String preceding the Org table
  after-string)   ; String following the Org table

(cl-defstruct org-table-highlight--metadata-table
  "Stores highlight metadata for a single Org table.
Includes the table's context and lists of highlighted columns and rows."
  context         ; An `org-table-highlight--metadata-context'
                  ; instance identifying the table
  col-highlights  ; Alist of (col-index :color COLOR) for highlighted columns
  row-highlights) ; Alist of (row-index :color COLOR) for highlighted rows

(cl-defstruct org-table-highlight--metadata-buffer
  "Top-level structure storing all table highlight metadata for a buffer.
Holds the buffer name and a list of`org-table-highlight--metadata-table'
instances associated with it."
  name            ; Buffer name (string)
  tables)         ; List of `org-table-highlight--metadata-table'
                  ; structs in the buffer

(defun org-table-highlight--metadata--get-buffer (buffer-name)
  "Return the buffer struct whose name matches BUFFER-NAME.

Returns nil if no such buffer is found."
  (cl-find buffer-name org-table-highlight--metadata
           :key #'org-table-highlight--metadata-buffer-name
           :test #'equal))

(defun org-table-highlight--metadata--get-table (buf-meta table-context)
  "Return the table struct from BUF-META whose context matches TABLE-CONTEXT.

Two contexts are considered equal if both their name and before-string
fields are equal.  Returns nil if no matching table is found.

Note: after-string is *not* used for matching."
  (cl-find-if
   (lambda (entry)
     (let ((ctx (org-table-highlight--metadata-table-context entry)))
       (and (equal (org-table-highlight--metadata-context-name ctx)
                   (org-table-highlight--metadata-context-name table-context))
            (equal (org-table-highlight--metadata-context-before-string ctx)
                   (org-table-highlight--metadata-context-before-string table-context)))))
   (org-table-highlight--metadata-buffer-tables buf-meta)))

(defun org-table-highlight--cleanup-metadata (buf-meta table-meta)
  "Clean up TABLE-META and BUF-META from metadata if they are empty.

- If TABLE-META has no column or row highlights, it is removed from BUF-META.
- If BUF-META has no tables remaining, it is removed from the global
  `org-table-highlight--metadata' list."
  ;; Remove TABLE-META from BUF-META if both highlights are empty
  (when (and table-meta
             (and (null (org-table-highlight--metadata-table-col-highlights table-meta))
                  (null (org-table-highlight--metadata-table-row-highlights table-meta))))
    (setf (org-table-highlight--metadata-buffer-tables buf-meta)
                   (delete table-meta (org-table-highlight--metadata-buffer-tables buf-meta))))

  ;; Remove BUF-META from global metadata if it has no tables left
  (when (and buf-meta
             (null (org-table-highlight--metadata-buffer-tables buf-meta)))
    (setq org-table-highlight--metadata
          (delete buf-meta org-table-highlight--metadata))))

(defun org-table-highlight--update-metadata
    (buffer-name table-context type index color predicate extend &optional remove)
  "Update highlight metadata for a specific Org table.

This function updates the internal `org-table-highlight--metadata' structure
by either adding or removing a highlight for a specific column or row in a
specific table within a specific buffer.

BUFFER-NAME is the name of the buffer.
TABLE-CONTEXT uniquely identifies the Org table.
TYPE is either \='col or \='row.
INDEX is the column or row number to update.
COLOR is the highlight color string (e.g. \"#FF0000\").
PREDICATE is string used to store a test condition for conditional highlighting.
EXTEND, if non-nil, extend the conditional highlight for whole row or column.
If REMOVE is non-nil, the entry at INDEX is removed; otherwise it's added."
  
  (let* ((buf-meta
          ;; Find buffer metadata, creating it if it nils when adding a highlight..
          (or (org-table-highlight--metadata--get-buffer buffer-name)
              (unless remove
                (let ((new-index (make-org-table-highlight--metadata-buffer
                            :name buffer-name :tables nil)))
                  (push new-index org-table-highlight--metadata)
                  new-index))))
         (table-meta
          ;; Find table metadata, creating it only if adding a highlight.
          (and buf-meta
               (or (org-table-highlight--metadata--get-table buf-meta table-context)
                   (unless remove
                     (let ((new-index (make-org-table-highlight--metadata-table
                                 :context table-context
                                 :col-highlights nil
                                 :row-highlights nil)))
                       (push new-index (org-table-highlight--metadata-buffer-tables buf-meta))
                       new-index))))))

    ;; Proceed only if a table metadata entry exists (or was created).
    (when table-meta
      ;; 1. Update the table's context if the surrounding text has changed.
      (let* ((stored-context (org-table-highlight--metadata-table-context table-meta))
             (new-after-string (org-table-highlight--metadata-context-after-string table-context)))
        (unless (equal (org-table-highlight--metadata-context-after-string stored-context)
                       new-after-string)
          (setf (org-table-highlight--metadata-context-after-string stored-context)
                new-after-string)))

      ;; 2. Modify the highlights list for the specified type (col or row).
      (let ((highlights-accessor (if (eq type 'col)
                                     #'org-table-highlight--metadata-table-col-highlights
                                   #'org-table-highlight--metadata-table-row-highlights))
            (highlights-setter (if (eq type 'col)
                                   (lambda (tbl val) (setf (org-table-highlight--metadata-table-col-highlights tbl) val))
                                 (lambda (tbl val) (setf (org-table-highlight--metadata-table-row-highlights tbl) val)))))
        (if (null index)
            ;; Clear all highlights of this type if INDEX is nil and REMOVE is true.
            (when remove (funcall highlights-setter table-meta nil))
          ;; Add or remove a highlight for a specific INDEX.
          (let* ((current-highlights (funcall highlights-accessor table-meta))
                 (filtered-highlights (cl-remove-if (lambda (entry) (= (car entry) index)) current-highlights)))
            (funcall highlights-setter table-meta
                     (if remove
                         filtered-highlights
                       ;; Add a new-index entry to the list.
                       (let ((new-entry (list index :color color)))
                         (when predicate
                           (setq new-entry (cons index (plist-put (cdr new-entry) :predicate predicate)))
                           (when extend
                             (setq new-entry (cons index (plist-put (cdr new-entry) :extend t)))))
                         (cons new-entry filtered-highlights))))))))
    
    (org-table-highlight--cleanup-metadata buf-meta table-meta)
    
    ;; Persist the changes to the metadata file.
    (org-table-highlight-save-metadata)))

(defun org-table-highlight--table-bounds ()
  "Return the (START . END) buffer positions of the current Org table."
  (when (org-at-table-p)
    (cons (save-excursion (org-table-begin))
          (save-excursion (org-table-end)))))

(defun org-table-highlight--next-color (counter)
  "Return the next color from the palette using COUNTER."
  (nth (mod counter (length org-table-highlight-color-palette))
       org-table-highlight-color-palette))

(defun org-table-highlight--make-overlay (start end &rest properties)
  "Create an overlay from START to END with overlay PROPERTIES.

PROPERTIES is a plist of additional overlay properties like :symbol value."
  (let ((ov (make-overlay start end)))
    (overlay-put ov 'evaporate t)
    (while properties
      (let ((prop (pop properties))
            (val  (pop properties)))
        (overlay-put ov prop val)))
    ov))

(defun org-table-highlight--remove-overlays (start end &optional type index)
  "Delete overlays between START and END with `org-table-highlight' property.

Only remove overlays where `:org-table-highlight` is TYPE (e.g., \='col
or \='row).  If INDEX is non-nil, also match `:index` to INDEX."
  (dolist (ov (overlays-in start end))
    (when (or (null type)
              (and (equal (overlay-get ov 'org-table-highlight) type)
                   (or (null index)
                       (equal (overlay-get ov 'index) index))))
      (delete-overlay ov))))

(defun org-table-highlight-debug-overlays-at-point ()
  "Print debug info for all org-table-highlight overlays at point."
  (interactive)
  (let ((overlays (overlays-at (point))))
    (if overlays
        (dolist (ov overlays)
          (when-let* ((type (overlay-get ov 'org-table-highlight))
                      (index (overlay-get ov 'index)))
            (message
             (concat
              "Overlay: %S\n"
              "  Range     : %d – %d\n"
              "  Face      : %S\n"
              "  Priority  : %S\n"
              "  Evaporate : %S\n"
              "  Type      : %S\n"
              "  Index     : %S\n"
              "  Predicate : %S\n"
              "  Extend    : %S")
             ov
             (overlay-start ov)
             (overlay-end ov)
             (overlay-get ov 'face)
             (overlay-get ov 'priority)
             (overlay-get ov 'evaporate)
             (pcase type
              ('col 'column)
              ('row 'row)
              (_ 'unknown))
             index
             (overlay-get ov 'predicate)
             (overlay-get ov 'extend))))
      (message "No overlays at point."))))

(defun org-table-highlight--get-table-name ()
  "Try to get the Org table name via #+NAME."
  (when-let* ((table (org-element-lineage
                      (org-element-context) 'table t)))
    (plist-get (cadr table) :name)))

(defun org-table-highlight--overlayp (type &optional index)
  "Return non-nil if an overlay with TYPE (and optional INDEX) exists at point.

If INDEX is non-nil, only return true if :index equals index."
  (cl-some (lambda (ov)
             (let ((ov-type (overlay-get ov 'org-table-highlight)))
               (and (equal ov-type type)
                    (or (not index) (equal (overlay-get ov 'index) index)))))
           (overlays-at (point))))

(defcustom org-table-highlight-table-context-length 20
  "Number of characters before and after an Org table to save as context.

This context helps identify the table uniquely when it lacks a #+NAME:
property.  It is used to match and restore highlights across sessions by
storing a short prefix and suffix string around the table position."
  :type 'integer
  :group 'org-table-highlight)

(defun org-table-highlight--table-context ()
  "Return contextual metadata for the Org table at point.

This includes the table's name (if any), a short string before the table,
and a short string after it, used to help identify the table if it has
no #+NAME:.  The length of these strings is controlled by
`org-table-highlight-table-context-length'."
  (when (org-at-table-p)
    (save-excursion
      (let* ((table-name (org-table-highlight--get-table-name))
             (begin (org-table-begin))
             (before-string
              (buffer-substring-no-properties
               (max (point-min) (- begin org-table-highlight-table-context-length))
               begin))
             (after-string
              (buffer-substring-no-properties
               begin
               (min (point-max) (+ begin org-table-highlight-table-context-length)))))
        (make-org-table-highlight--metadata-context
         :name table-name
         :before-string before-string
         :after-string after-string)))))

(defun org-table-highlight--parse-comparator (expr)
  "Convert a comparator EXPR like \">100\" or \"=TODO\" to a comparison form.
Supports numeric and string values."
  (let* ((re "^\\(<=\\|>=\\|<\\|>\\|=\\|!=\\|/=\\)\\s-*\\(.+\\)$")
         (match (string-match re expr)))
    (if match
        (let* ((op (match-string 1 expr))
               (val-str (match-string 2 expr))
               (op-symbol (if (string= op "!=") '/= (intern op)))
               (is-num (string-match-p "\\`[0-9.]+\\'" val-str))
               (val-expr (if is-num
                             `(string-to-number val)
                           `val))
               (comp-val (if is-num
                             (string-to-number val-str)
                           val-str)))
          (cond
           ((member op-symbol '(= /=))
            ;; String equality/inequality or numeric
            (if is-num
                ;; numeric comparison
                `(,op-symbol ,val-expr ,comp-val)
              ;; string equality/inequality
              (if (eq op-symbol '=)
                  `(string= val ,comp-val)
                `(not (string= val ,comp-val)))))
           (t
            ;; For <, >, <=, >= only numeric supported
            (if is-num
                `(,op-symbol ,val-expr ,comp-val)
              (error "Operator %s not supported for non-numeric value %s" op val-str)))))
      (error "Invalid comparator expression: %s" expr))))

(defun org-table-highlight--parse-and-expr (expr)
  "Parse a subexpression EXPR with and logic."
  (let* ((parts (split-string expr "\\s-+and\\s-+"))
         (conditions (mapcar #'org-table-highlight--parse-comparator parts)))
    `(and ,@conditions)))

(defun org-table-highlight--parse-comparison (expr)
  "Parse expressions EXPR with `and` and `or`, like \">10 and <100 or =TODO\".
Returns a lambda that takes a string VAL."
  (let* ((or-parts (split-string expr "\\s-+or\\s-+"))
         (and-forms (mapcar #'org-table-highlight--parse-and-expr or-parts)))
    `(lambda (val) (or ,@and-forms))))

(defun org-table-highlight--overlay-priority (table-meta)
  "Compute an overlay priority for new-index highlights in TABLE-META.

If TABLE-META is nil, return a default priority (e.g., 100)."
  (if (null table-meta)
      100
    (+ 100
       (length (org-table-highlight--metadata-table-col-highlights table-meta))
       (length (org-table-highlight--metadata-table-row-highlights table-meta)))))

;;;###autoload
(defun org-table-highlight-column (&optional color predicate extend)
  "Highlight the current Org table column with a cycling or user-supplied COLOR.

- With a prefix argument (\\[universal-argument]), prompt for a color.
- With a double prefix argument, prompt for a conditional PREDICATE.
  PREDICATE is a string expression like '>10', '=TODO', or '>=50 and <=100'.
  Only cells that satisfy this will be highlighted.
- With a triple prefix argument, also EXTEND the highlight to the whole row."
  (interactive
   (list
    (when current-prefix-arg (read-color "Column color: " t))
    (when (member current-prefix-arg '((16) (64))) (read-string "Predicate expr (val): "))
    (when (equal current-prefix-arg '(64)) t)))

  ;; Ensure we're inside a table
  (unless (org-at-table-p)
    (user-error "Not in an Org table"))
  
  (let* ((buf-name (buffer-name))
         (table-context (org-table-highlight--table-context))
         (table-meta
          (when-let* ((buf-meta (org-table-highlight--metadata--get-buffer buf-name)))
            (org-table-highlight--metadata--get-table buf-meta table-context)))
         (highlighted-columns-count
          (if table-meta
              (length (org-table-highlight--metadata-table-col-highlights table-meta))
            0))
         (priority (org-table-highlight--overlay-priority table-meta))
         (col (org-table-current-column))
         (chosen-color (or color (org-table-highlight--next-color
                                  highlighted-columns-count)))
         (bounds (org-table-highlight--table-bounds))
         (predicate-fn (when predicate
                         (org-table-highlight--parse-comparison predicate))))

    ;; Save metadata
    (org-table-highlight--update-metadata
     buf-name table-context 'col col chosen-color predicate extend)

    ;; Apply overlays inside narrowed region
    (save-restriction
      (narrow-to-region (car bounds) (cdr bounds))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((beg (point)) (end (line-end-position)) (i 0))
            (while (and (< i col)
                        (re-search-forward
                         (if (org-at-table-hline-p) "[|\\+]" "|")
                         end t))
              (setq beg (point))
              (setq i (1+ i)))
            (unless (org-table-highlight--overlayp 'col)
              (setq end (progn (skip-chars-forward (if (org-at-table-hline-p) "-" "^|"))
                               (point)))
              (when (or (null predicate-fn)
                        (funcall predicate-fn
                                 (string-trim (buffer-substring-no-properties beg end))))
                (if extend
                    (org-table-highlight--make-overlay
                     (save-excursion (beginning-of-line) (back-to-indentation) (point))
                     (save-excursion (end-of-line) (skip-chars-backward "^|") (point))
                     'org-table-highlight 'col
                     'index col
                     'face `(:background ,chosen-color)
                     'help-echo (when predicate (format "Predicate: %s" predicate))
                     'priority priority
                     'predicate predicate
                     'extend t)
                  (org-table-highlight--make-overlay
                   beg end
                   'org-table-highlight 'col
                   'index col
                   'face `(:background ,chosen-color)
                   'priority priority
                   'predicate predicate)))))
          (forward-line 1))))))

;;;###autoload
(defun org-table-highlight-row (&optional color)
  "Highlight the current Org table row with a cycling or user-supplied COLOR.
With a prefix argument (\\[universal-argument]), prompt for a color."
  (interactive
   (list (when current-prefix-arg (read-color "Row color: " t))))

  (unless (org-at-table-p)
    (user-error "Not in an Org table"))
  
  (let* ((buf-name (buffer-name))
         (table-context (org-table-highlight--table-context))
         (table-meta
          (when-let* ((buf-meta (org-table-highlight--metadata--get-buffer buf-name)))
            (org-table-highlight--metadata--get-table buf-meta table-context)))
         (highlighted-rows-count
          (if table-meta
              (length (org-table-highlight--metadata-table-row-highlights table-meta))
            0))
         (priority (org-table-highlight--overlay-priority table-meta))
         (row (org-table-current-line))
         (chosen-color (or color (org-table-highlight--next-color highlighted-rows-count)))
         (start (save-excursion (beginning-of-line) (back-to-indentation) (point)))
         (end (save-excursion (end-of-line) (skip-chars-backward "^|") (point))))
    (org-table-highlight--update-metadata buf-name table-context 'row row chosen-color nil nil)
    (unless (org-table-highlight--overlayp 'row)
      (org-table-highlight--make-overlay start end
                                         'face `(:background ,chosen-color)
                                         'org-table-highlight 'row
                                         'index row
                                         'priority priority))))

(defun org-table-highlight-restore-table (&optional type index)
  "Restore highlights for the Org table at point using stored metadata.

If TYPE is nil, all column and row highlights are restored.  If TYPE is
\='col or \='row, only the corresponding type of highlights is restored.

If INDEX is provided, only the highlight at that column or row index is
restored.  This is useful for restoring a single updated highlight after
a structural change."
  (interactive)
  (when (org-at-table-p)
    (when-let* ((buffer-name (buffer-name))
                (table-context (org-table-highlight--table-context))
                (buf-meta (org-table-highlight--metadata--get-buffer buffer-name))
                (table-meta (org-table-highlight--metadata--get-table buf-meta table-context)))

      ;; Reapply column highlights
      (when (or (null type) (eq type 'col))
        (dolist (col-entry (org-table-highlight--metadata-table-col-highlights table-meta))
          (cl-destructuring-bind (col . props) col-entry
            (let ((color (plist-get props :color))
                  (predicate (plist-get props :predicate))
                  (extend (plist-get props :extend)))
              (when (or (null index) (= index col))
                (save-excursion
                  (org-table-goto-column col)
                  (org-table-highlight-column color predicate extend)))))))

      ;; Reapply row highlights
      (when (or (null type) (eq type 'row))
        (dolist (row-entry (org-table-highlight--metadata-table-row-highlights table-meta))
          (cl-destructuring-bind (row . props) row-entry
            (let ((color (plist-get props :color)))
              (when (or (null type) (= index row))
                (save-excursion
                  (org-table-goto-line row)
                  (org-table-highlight-row color))))))))))

;;;###autoload
(defun org-table-highlight-clear-column-highlights (&optional all)
  "Clear highlights in the current Org table column, or all columns.

With a prefix argument ALL, clear all column highlights in the
current table.  Otherwise, clear only the highlight in the
current column."
  (interactive "P")
  (unless (org-at-table-p)
    (user-error "Not in an Org table"))

  (let ((col-to-clear (unless all (org-table-current-column))))
    (when (or (not col-to-clear)
              (org-table-highlight--overlayp 'col col-to-clear))
      (when-let* ((buf-name (buffer-name))
                  (table-context (org-table-highlight--table-context))
                  (bounds (org-table-highlight--table-bounds)))
        (org-table-highlight--update-metadata
         buf-name table-context 'col col-to-clear nil nil nil 'remove)
        (org-table-highlight--remove-overlays
         (car bounds) (cdr bounds) 'col col-to-clear)))))

;;;###autoload
(defun org-table-highlight-clear-row-highlights (&optional all)
  "Clear highlights in current Org table row.
With prefix argument ALL, clear all row highlights."
  (interactive "P")
  (unless (org-at-table-p)
    (user-error "Not in an Org table"))
  
  (let ((row-to-clear (unless all (org-table-current-line))))
    (when (or (not row-to-clear)
              (org-table-highlight--overlayp 'row row-to-clear))
      (when-let* ((buf-name (buffer-name))
                  (table-context (org-table-highlight--table-context))
                  (bounds (org-table-highlight--table-bounds)))
        (org-table-highlight--update-metadata
           buf-name table-context 'row row-to-clear nil nil nil 'remove)
        (org-table-highlight--remove-overlays
         (car bounds) (cdr bounds) 'row row-to-clear)))))

;;;###autoload
(defun org-table-highlight-clear-all-highlights (&optional keep-metadata)
  "Clear all column and row highlights in current Org table.

Keep metadata if KEEP-METADATA non-nils."
  (interactive "P")
  (unless (org-at-table-p)
    (user-error "Not in an Org table"))
  
  (when-let* ((bounds (org-table-highlight--table-bounds)))
    (org-table-highlight--remove-overlays (car bounds) (cdr bounds)))
  
  (unless keep-metadata
    (when-let* ((buf-name (buffer-name))
                (table-context (org-table-highlight--table-context)))
      (org-table-highlight--update-metadata
       buf-name table-context 'col nil nil nil nil 'remove)
      (org-table-highlight--update-metadata
       buf-name table-context 'row nil nil nil nil 'remove))))

(defun org-table-highlight--remove-plist-key (plist key)
  "Return a copy of PLIST with KEY and its value removed."
  (let (new-plist)
    (while plist
      (let ((k (pop plist))
            (v (pop plist)))
        (unless (eq k key)
          (setq new-plist (plist-put new-plist k v)))))
    new-plist))

(defcustom org-table-highlight-metadata-file
  (locate-user-emacs-file "org-table-highlight-metadata.el")
  "File where Org table highlight metadata is saved."
  :type 'file
  :group 'org-table-highlight)

(defun org-table-highlight-save-metadata ()
  "Save `org-table-highlight--metadata` to `org-table-highlight-metadata-file'."
  (interactive)
  (condition-case nil
      (with-temp-file org-table-highlight-metadata-file
        (insert ";;; org-table-highlight saved metadata. ")
        (insert "Do not edit this file.\n\n")
        (pp org-table-highlight--metadata (current-buffer))
        (insert "\n"))
    (error "Cannot save metadata to %s" org-table-highlight-metadata-file)))

;;;###autoload
(defun org-table-highlight-load-metadata ()
  "Load Org table highlight metadata from `org-table-highlight-metadata-file'."
  (interactive)
  (when (file-exists-p org-table-highlight-metadata-file)
    (condition-case nil
        (progn (setq org-table-highlight--metadata
                     (with-temp-buffer
                       (insert-file-contents org-table-highlight-metadata-file)
                       (goto-char (point-min))
                       (read (current-buffer))))
               (message "org-table-highlight--metadata variable loaded"))
      (error "Cannot read metadata at %s" org-table-highlight-metadata-file))))

(defun org-table-highlight--get-table-position (context)
  "Get position of table beginning position based on CONTEXT."
  (save-excursion
    (let ((name (org-table-highlight--metadata-context-name context))
          (before-string (org-table-highlight--metadata-context-before-string context))
          (after-string (org-table-highlight--metadata-context-after-string context))
          point)

      (goto-char (point-min))

      (if name
          (progn (re-search-forward (format "#\\+NAME:[ \t]*%s" (regexp-quote name)) nil t)
                 (setq point (1+ (point))))

        (if (and before-string (search-forward before-string (point-max) t))
            (progn
              (goto-char (match-end 0))
              (setq point (point))))

        (if (and after-string (search-forward after-string (point-max) t))
            (progn
              (goto-char (match-beginning 0))
              (setq point (point)))))
      point)))

;;;###autoload
(defun org-table-highlight-restore-buffer ()
  "Apply highlight metadata to all tables in the current buffer."
  (interactive)
  (org-table-highlight-load-metadata)
  (when-let* ((buf-meta (org-table-highlight--metadata--get-buffer (buffer-name))))
    (dolist (table-meta (org-table-highlight--metadata-buffer-tables buf-meta))
      (let* ((table-context (org-table-highlight--metadata-table-context table-meta))
             (pos (org-table-highlight--get-table-position table-context)))
        (save-excursion
          (when (and pos (goto-char pos))
            ;; Apply columns
            (dolist (col-entry (org-table-highlight--metadata-table-col-highlights table-meta))
              (cl-destructuring-bind (col . props) col-entry
                (let ((color (plist-get props :color))
                      (predicate (plist-get props :predicate))
                      (extend (plist-get props :extend)))
                  (org-table-goto-column col)
                  (org-table-highlight-column color predicate extend))))
            ;; Apply rows
            (dolist (row-entry (org-table-highlight--metadata-table-row-highlights table-meta))
              (cl-destructuring-bind (row . props) row-entry
                (let ((color (plist-get props :color)))
                  (goto-char (org-table-begin))
                  (org-table-goto-line row)
                  (org-table-highlight-row color))))))))))

(defun org-table-highlight--collect-table-metadata (tbl)
  "Collect highlight metadata from TBL (an `org-element' table).

Returns a metadata entry of the form:
  ((:name NAME :before-string STR :after-string STR)
   :col ((N :color COLOR :predicate PREDICATE :extend t))
   :row ((N :color COLOR :predicate PREDICATE)))
or nil if there are no highlight overlays."
  (let* ((begin (org-element-property :contents-begin tbl))
         (end (org-element-property :contents-end tbl))
         (overlays (overlays-in begin end))
         (col-highlights '())
         (row-highlights '()))
    (when overlays
      (dolist (ov overlays)
        (let* ((type (overlay-get ov 'org-table-highlight))
               (index (overlay-get ov 'index))
               (predicate (overlay-get ov 'predicate))
               (extend (overlay-get ov 'extend))
               (color (plist-get (overlay-get ov 'face) :background))
               (indice (list index :color color)))
          (when predicate
            (setq indice (cons index (plist-put (cdr indice) 'predicate predicate)))
            (when extend
              (setq indice (cons index (plist-put (cdr indice) 'extend t)))))
          (pcase type
            ('col (cl-pushnew indice col-highlights :test #'equal))
            ('row (cl-pushnew indice row-highlights :test #'equal)))))
      (when (or col-highlights row-highlights)
        (save-excursion
          (goto-char begin)
          (let ((context (org-table-highlight--table-context)))
            (make-org-table-highlight--metadata-table
             :context context
             :col-highlights (nreverse col-highlights)
             :row-highlights (nreverse row-highlights))))))))

(defun org-table-highlight--refresh-buffer-metadata ()
  "Collect highlight metadata from all tables in the current buffer.

Returns a list of entries of the form:
  ((:name NAME :before-string STR :after-string STR)
   :col ((N . COLOR)) :row ((N . COLOR)))."
  (interactive)
  (when (derived-mode-p 'org-mode)
    (let* ((buf-meta (org-table-highlight--metadata--get-buffer (buffer-name)))
           (table-meta
            (cl-remove-if-not #'identity
                              (org-element-map (org-element-parse-buffer) 'table
                                #'org-table-highlight--collect-table-metadata))))
      (when buf-meta
        (setf (org-table-highlight--metadata-buffer-tables buf-meta) table-meta)

        (when (null (org-table-highlight--metadata-buffer-tables buf-meta))
          (setq org-table-highlight--metadata
                (delete buf-meta org-table-highlight--metadata)))

        (org-table-highlight-save-metadata)))))

(defun org-table-highlight--fix-indice-1 (index ref-index handle entry table-meta)
  "Adjust a highlight ENTRY in TABLE-META depending on HANDLE and position.

Arguments:
- INDEX: The index of the highlight (i.e., (car ENTRY)).
- REF-INDEX: The index at which the table changed (insert/delete/move).
- HANDLE: One of:
  - insert / above → Inserted at REF-INDEX: increment if INDEX >= REF-INDEX.
  - delete / delete-row / delete-column:
      → Remove if INDEX == REF-INDEX.
      → Decrement if INDEX > REF-INDEX.
  - left / up → Shift left if after REF-INDEX, right if at REF-INDEX.
  - right / down → Shift right if before REF-INDEX, left if at REF-INDEX.

Return nil if unchanged, or a plist like:
  (:changed OLD NEW)
  (:removed OLD)"
  (let ((old-index index) (changed t))
    
    (pcase handle
      ;; Insertion shifts highlights at or after insertion index
      ((or 'insert 'above)
       (when (>= index ref-index)
         (setcar entry (1+ index))))

      ;; Deletion may remove or shift
      ((or 'delete-row 'delete-column)
       (cond
        ((= index ref-index)
         ;; Remove ENTRY from the correct list
         (pcase handle
           ('delete-row
            (setf (org-table-highlight--metadata-table-row-highlights table-meta)
                  (cl-remove-if (lambda (r) (= (car r) index))
                                (org-table-highlight--metadata-table-row-highlights table-meta))))
           ('delete-column
            (setf (org-table-highlight--metadata-table-col-highlights table-meta)
                  (cl-remove-if (lambda (c) (= (car c) index))
                                (org-table-highlight--metadata-table-col-highlights table-meta)))))
         (setq changed :removed))
        ((> index ref-index)
         (setcar entry (1- index)))))

      ;; Reordering (left/up/down/right)
      ((or 'left 'up)
       (cond
        ((= index ref-index)
         (setcar entry (1+ index)))
        ((= index (1+ ref-index))
         (setcar entry (1- index)))))

      ((or 'right 'down)
       (cond
        ((= index ref-index)
         (setcar entry (1- index)))
        ((= index (1- ref-index))
         (setcar entry (1+ index)))))
      
      (_ (setq changed nil)))

    (cond
     ((eq changed :removed) `(:removed ,old-index))
     (changed `(:changed ,old-index ,(car entry)))
     (t nil))))

(defun org-table-highlight--fix-indice (handle)
  "Update highlight metadata after a column or row is inserted or deleted.

HANDLE must be either \='insert or \='delete.  This function adjusts the
metadata for the current Org table in `org-table-highlight--metadata' to
reflect changes caused by the insertion or deletion of a column or row at point.

It does the following:
1. Finds the column and row index at point.
2. Locates the corresponding highlight metadata entry using table context (such
   as name and nearby content).
3. Adjusts all metadata entries (i.e., highlighted columns and rows) that occur
   after the insertion/deletion point, shifting their indices accordingly or
   removing entries that are deleted.
4. Clear all overlays changed, then restores them based on the updated metadata.
5. Updates the metadata in `org-table-highlight--metadata' accordingly.

This function is intended to be called after structural edits (e.g., with
`org-table-insert-column', `org-table-delete-row', etc.)."
  (save-excursion
    (when-let* ((buf-meta (org-table-highlight--metadata--get-buffer (buffer-name)))
                (table-context (org-table-highlight--table-context))
                (table-meta (org-table-highlight--metadata--get-table buf-meta table-context))
                (bounds (org-table-highlight--table-bounds)))
      (let ((changed '())
            (removed '()))
        ;; Columns
        (unless (memq handle '(up down below above delete-row))
          (let ((ref-col (org-table-current-column)))
            (dolist (col (org-table-highlight--metadata-table-col-highlights table-meta))
              (when-let ((r (org-table-highlight--fix-indice-1
                             (car col) ref-col handle col table-meta)))
                (pcase r
                  (`(:removed ,i) (push `(col . ,i) removed))
                  (`(:changed ,old ,new) (push `(col . (,old . ,new)) changed)))))))

        ;; Rows
        (unless (memq handle '(left right delete-column))
          (let ((ref-row (org-table-current-line)))
            (dolist (row (org-table-highlight--metadata-table-row-highlights table-meta))
              (when-let ((r (org-table-highlight--fix-indice-1
                             (car row) ref-row handle row table-meta)))
                (pcase r
                  (`(:removed ,i) (push `(row . ,i) removed))
                  (`(:changed ,old ,new) (push `(row . (,old . ,new)) changed)))))))

        ;; Remove overlays
        (dolist (entry (append removed changed))
          (pcase entry
            (`(col . ,i)
             (org-table-highlight--remove-overlays (car bounds) (cdr bounds)
                                                   'col (if (consp i) (car i) i)))
            (`(row . ,i)
             (org-table-highlight--remove-overlays (car bounds) (cdr bounds)
                                                   'row (if (consp i) (car i) i)))))

        (org-table-highlight-restore-table)
        (org-table-highlight--cleanup-metadata buf-meta table-meta)
        (org-table-highlight-save-metadata)))))

(defun org-table-highlight-clear-buffer-overlays ()
  "Clear all Org table highlight overlays in the current buffer.

This removes both column and row highlights overlays across the entire
buffer, regardless of table context."
  (interactive)
  (org-table-highlight--remove-overlays (point-min) (point-max))
  (message "All Org table highlight overlays removed from buffer."))

;;;###autoload
(defun org-table-highlight-list-all (&optional buffers-to-process)
  "List highlighted Org tables.

BUFFERS-TO-PROCESS is the list of buffer to display the highlight.
Behavior depends on the prefix argument (\\[universal-argument]):
- No prefix: List tables in the current buffer.
- One prefix: Prompt for a buffer to list.
- Two prefixes: List tables from all buffers with known highlight metadata."
  (interactive
   (let ((all-buffers-with-meta
          (cl-loop for b-meta in org-table-highlight--metadata
                   collect (get-buffer (org-table-highlight--metadata-buffer-name b-meta)))))
     (list
      (pcase current-prefix-arg
        ;; C-u C-u: Use all buffers
        ('(16) all-buffers-with-meta)

        ;; C-u: Prompt for one buffer
        ('(4) (if all-buffers-with-meta
                  (list (get-buffer
                         (completing-read "List highlights for buffer: "
                                          (mapcar #'buffer-name all-buffers-with-meta)
                                          nil t)))
                (progn (message "No highlight metadata found.") nil)))

        ;; No prefix: Use current buffer
        (_ (list (current-buffer)))))))

  (when buffers-to-process
    (with-help-window (get-buffer-create "*Org Table Highlights*")
      (let ((first-buffer t))
        (dolist (buffer buffers-to-process)
          ;; Print a header if processing multiple buffers
          (if first-buffer
              (setq first-buffer nil)
            (princ "\n\n"))
          (princ (format "--- Highlights in %s --\n\n" (buffer-name buffer)))
          (if-let* ((buffer-name (buffer-name buffer))
                    (buf-meta (org-table-highlight--metadata--get-buffer buffer-name))
                    (tables (org-table-highlight--metadata-buffer-tables buf-meta)))
              (dolist (table-meta tables)
                (let* ((context (org-table-highlight--metadata-table-context table-meta))
                       (name (org-table-highlight--metadata-context-name context))
                       (pos (with-current-buffer buffer
                              (org-table-highlight--get-table-position context)))
                       (num-cols (length (org-table-highlight--metadata-table-col-highlights table-meta)))
                       (num-rows (length (org-table-highlight--metadata-table-row-highlights table-meta))))
                  (princ (format "- Table %s" (or name "(unnamed)")))
                  (when pos
                    (insert-button
                     " [jump]"
                     'action `(lambda (_)
                                (pop-to-buffer ',buffer)
                                (goto-char ,pos))
                     'follow-link t))
                  (princ (format " (%d columns, %d rows highlighted)\n" num-cols num-rows))))
            ;; Message if a specific buffer in the list had no highlights
            (unless (org-table-highlight--metadata--get-buffer (buffer-name buffer))
              (princ (format "(No highlights found in %s)\n" (buffer-name buffer))))))))))

(defun org-table-highlight--after-insert-column ()
  "Advice: Fix highlight indices after inserting a column."
  (org-table-highlight--fix-indice 'insert))

(defun org-table-highlight--after-delete-column ()
  "Advice: Fix highlight indices after deleting a column."
  (org-table-highlight--fix-indice 'delete-column))

(defun org-table-highlight--after-move-column (&optional move)
  "Advice: Fix highlight indices after moving a column.
When MOVE non-nils, move column right"
  (org-table-highlight--fix-indice (or move 'right)))

(defun org-table-highlight--after-insert-row (&optional arg)
  "Advice: Fix highlight indices after inserting a row.
When ARG nils, insert above, otherwise insert below."
  (org-table-highlight--fix-indice (if arg 'below 'above)))

(defun org-table-highlight--after-kill-row ()
  "Advice: Fix highlight indices after killing a row."
  (org-table-highlight--fix-indice 'delete-row))

(defun org-table-highlight--after-move-row (&optional move)
  "Advice: Fix highlight indices after moving a row.
When MOVE non-nils, move row down."
  (org-table-highlight--fix-indice (or move 'down)))

(defun org-table-highlight--enable-advice ()
  "Enable all org-table-highlight related advices."
  (advice-add 'org-table-align :after #'org-table-highlight-restore-table)
  (advice-add 'org-table-insert-column :after #'org-table-highlight--after-insert-column)
  (advice-add 'org-table-delete-column :after #'org-table-highlight--after-delete-column)
  (advice-add 'org-table-move-column :after #'org-table-highlight--after-move-column)
  (advice-add 'org-table-insert-row :after #'org-table-highlight--after-insert-row)
  (advice-add 'org-table-kill-row :after #'org-table-highlight--after-kill-row)
  (advice-add 'org-table-move-row :after #'org-table-highlight--after-move-row))

(defun org-table-highlight--disable-advice ()
  "Disable all org-table-highlight related advices."
  (advice-remove 'org-table-align #'org-table-highlight-restore-table)
  (advice-remove 'org-table-insert-column #'org-table-highlight--after-insert-column)
  (advice-remove 'org-table-delete-column #'org-table-highlight--after-delete-column)
  (advice-remove 'org-table-move-column #'org-table-highlight--after-move-column)
  (advice-remove 'org-table-insert-row #'org-table-highlight--after-insert-row)
  (advice-remove 'org-table-kill-row #'org-table-highlight--after-kill-row)
  (advice-remove 'org-table-move-row #'org-table-highlight--after-move-row))

;;;###autoload
(define-minor-mode org-table-highlight-mode
  "Minor mode to enable or disable Org table highlighting.

When enabled:
- Highlights are automatically restored after table alignments or movements.
- Metadata is maintained and saved on buffer close.

When disabled:
- All highlights (overlays) in the current buffer are removed.
- All metadata for this buffer is cleared.
- Advices and hooks are disabled."
  :lighter " OrgTblHL"
  :group 'org-table-highlight
  (if org-table-highlight-mode
      (progn
        (org-table-highlight--enable-advice)
        (add-hook 'kill-buffer-hook #'org-table-highlight--refresh-buffer-metadata nil t)
        (org-table-highlight-restore-buffer)
        (message "org-table-highlight-mode enabled."))
    (progn
      (when (derived-mode-p 'org-mode)
        (org-table-highlight-clear-buffer-overlays))
      (org-table-highlight--disable-advice)
      (remove-hook 'kill-buffer-hook #'org-table-highlight--refresh-buffer-metadata t)
      (message "org-table-highlight-mode disabled: all highlights cleared, while metadata remains uncleared.."))))

(provide 'org-table-highlight)
;;; org-table-highlight.el ends here
