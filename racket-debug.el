;;; racket-debug.el -*- lexical-binding: t; -*-

;; Copyright (c) 2018 by Greg Hendershott.

;; Author: Greg Hendershott
;; URL: https://github.com/greghendershott/racket-mode

;; License:
;; This is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version. This is distributed in the hope that it will be
;; useful, but without any warranty; without even the implied warranty
;; of merchantability or fitness for a particular purpose. See the GNU
;; General Public License for more details. See
;; http://www.gnu.org/licenses/ for details.

(require 'racket-repl)
(require 'easymenu)
(require 'cl-lib)
(require 'rx)

(defun racket-project-files (file-to-run)
  "A suitable value for the variable `racket-debuggable-files'.
When projectile is installed and we're in a project, return all
its Racket files. Else return all Racket files in the same
directory as `file-to-run'. In all cases, include `file-to-run'.
In all cases, return absolute path names."
  (cons
   file-to-run
   (or
    (ignore-errors
      (require 'projectile)
      (when (and (fboundp 'projectile-project-root)
                 (fboundp 'projectile-dir-files))
        (let ((root (projectile-project-root)))
          (mapcar (lambda (v)
                    (expand-file-name v root))
                  (cl-remove-if-not (lambda (v)
                                      (and (member (file-name-extension v)
                                                   '("rkt" "ss" "scm" "scrbl"))
                                           v))
                                    (projectile-dir-files root))))))
    (directory-files (file-name-directory file-to-run)
                     t
                     (rx "." (or "rkt" "ss" "scm" "scrbl") eos)))))

(defvar racket-debuggable-files #'racket-project-files
  "Used to tell `racket-run' what files may be instrumented for debugging.
Must be a list of strings that are pathnames, such as from
`racket--buffer-file-name', -or-, a function that returns such a
list given the pathname of the file being run. If any path
strings are relative, they are made absolute using
`expand-file-name' with the directory of the file being run. The
symbol 'run-file may be supplied in the list; it will be replaced
with the pathname of the file being run. Safe to set as a
file-local variable.")

(defun racket--debuggable-files (file-to-run)
  "Do the work described in doc str for variable `racket-debuggable-files'."
  (cl-labels ((err (&rest args)
                   (user-error (concat "racket-debuggable-files: must be "
                                       (apply #'format args)))))
    (let* ((dir (file-name-directory file-to-run))
           (xs  (if (functionp racket-debuggable-files)
                    (funcall racket-debuggable-files file-to-run)
                  racket-debuggable-files))
           (xs  (if (listp xs) xs (err "a list but is `%S'" xs)))
           (xs  (mapcar
                 (lambda (v)
                   (pcase v
                     (`run-file      file-to-run)
                     ((pred stringp) (expand-file-name v dir))
                     (_              (err "string or 'run-file but is `%S' in `%S'"
                                          v xs))))
                 xs)))
      xs)))

(defvar racket--debug-break-positions nil)
(defvar racket--debug-break-locals nil)
(defvar racket--debug-break-info nil)
;; (U nil (cons break-id
;;              (U (list 'before)
;;                 (list 'after string-of-racket-write-values))))

;;;###autoload
(defun racket--debug-send-definition (beg end)
  (racket--cmd/async
   (save-excursion
     (goto-char beg)
     (list 'debug-eval
           (racket--buffer-file-name)
           (line-number-at-pos)
           (current-column)
           (point)
           (buffer-substring-no-properties (point) end)))
   (lambda (_)
     ;; TODO: Also set fringe, and/or set marker on function
     ;; name to show it's debuggable.
     (message "Now you can call the function in the REPL to step debug it.")))  )

;;;###autoload
(defun racket--debug-on-break (response)
  (pcase response
    (`((,src . ,pos) ,positions ,locals ,vals)
     (pcase (find-buffer-visiting src)
       (`nil (other-window 1) (find-file src))
       (buf  (pop-to-buffer buf)))
     (goto-char pos)
     (pcase vals
       (`(,_id before)   (message "Break before expression"))
       (`(,_id after ,s) (message "Break after expression: (values %s" (substring s 1))))
     (setq racket--debug-break-positions positions)
     (setq racket--debug-break-locals locals)
     (setq racket--debug-break-info vals)
     (racket-debug-mode 1))))

(defun racket--debug-resume (next-break value-prompt-p)
  (unless racket--debug-break-info (user-error "Not debugging"))
  (let ((info (if value-prompt-p
                  (racket--debug-prompt-for-new-values)
                racket--debug-break-info)))
    (racket--cmd/async `(debug-resume (,next-break ,info))))
  (racket-debug-mode -1)
  (setq racket--debug-break-positions nil)
  (setq racket--debug-break-locals nil)
  (setq racket--debug-break-info nil))

(defun racket--debug-prompt-for-new-values ()
  (pcase racket--debug-break-info
    (`(,id before)
     (pcase (read-from-minibuffer "Skip step, substituting values: " "()")
       ((or `nil "" "()") `(,id before))
       (str  `(,id before ,str))))
    (`(,id after ,orig)
     (pcase (read-from-minibuffer "Step, replacing result values: " orig)
       ((or `nil "" "()") `(,id after ,orig))
       (new  `(,id after ,new))))))

(defun racket-debug-step (&optional prefix)
  (interactive "P")
  (racket--debug-resume 'all prefix))

(defun racket-debug-continue (&optional prefix)
  (interactive "P")
  (racket--debug-resume 'none prefix))

(defun racket-debug-run-to-here (&optional prefix)
  (interactive)
  (racket--debug-resume (cons (racket--buffer-file-name) (point)) prefix))

(defun racket-debug-next-breakable ()
  (interactive)
  (racket--debug-goto-breakable t))

(defun racket-debug-prev-breakable ()
  (interactive)
  (racket--debug-goto-breakable nil))

(defun racket--debug-goto-breakable (forwardp)
  (pcase (assoc (racket--buffer-file-name) racket--debug-break-positions)
    (`(,_src . ,ps)
     (let ((ps   (if forwardp ps (reverse ps)))
           (pred (apply-partially (if forwardp #'< #'>) (point))))
       (goto-char (pcase (cl-find-if pred ps)
                    (`nil (car ps))
                    (v    v)))))
    (_ (user-error "No breakable positions in this buffer"))))

(defun racket-debug-disable ()
  (interactive)
  (racket--cmd/async `(debug-disable))
  (racket-debug-mode -1)
  (setq racket--debug-break-positions nil)
  (setq racket--debug-break-locals nil)
  (setq racket--debug-break-info nil))

(add-hook 'racket--repl-before-run-hook #'racket-debug-disable)

(defun racket-debug-help ()
  (interactive)
  (describe-function 'racket-debug-mode))

(defvar racket--debug-overlays nil)

(define-minor-mode racket-debug-mode
  "Minor mode for debug breaks.

> This feature is **EXPERIMENTAL**.

How to debug:

1. \"Instrument\" code for step debugging. You can instrument
   entire files, and also individual functions.

   a. Entire Files

      Choose `racket-run' with two prefixes -- C-u C-u C-c C-c. The
      file will be instrumented for step debugging before it is run.
      Also instrumented are files determined by the variable
      `racket-debuggable-files'.

   b. Function Definitions

      Put point in a function `define` form and C-u C-M-x to
      \"instrument\" the function for step debugging. You can do
      this for any number of functions.

      You can even do this while stopped at a break. For example, to
      instrument a function you are about to call, so you can \"step
      into\" it:

        - M-. a.k.a. `racket-visit-definition'.
        - C-u C-M-x to instrument the definition.
        - M-, a.k.a. `racket-unvisit'.
        - Continue stepping.

      A `racket-run' re-evaluates the .rkt file contents from
      scratch, \"undoing\" changes made solely in the REPL --
      including debug instrumentation.

      Limitation: Instrumenting a function `require`d from another
      module won't redefine that function. Instead, it attempts to
      define an instrumented function of the same name, in the
      module the REPL is inside. The define will fail if it needs
      definitions visible only in that other module.

2. In the *Racket REPL* buffer, enter an expression that causes
   instrumented functions to be called, directly or indirectly.

3. When a break occurs, `racket-debug-mode' is activated so you
   can use convenient keys. Also, the REPL prompt changes. In
   this debug REPL, local variables are available for you to
   reference and even to `set!`.


```
\\{racket-debug-mode-map}
```
"
  :lighter " Racket-DEBUG-BREAK"
  :keymap (racket--easy-keymap-define
           '(("SPC" racket-debug-step)
             ("c"   racket-debug-continue)
             ("n"   racket-debug-next-breakable)
             ("p"   racket-debug-prev-breakable)
             ("h"   racket-debug-run-to-here)
             ("?"   racket-debug-help)))
  (unless (eq major-mode 'racket-mode)
    (setq racket-debug-mode nil)
    (user-error "racket-debug-mode only works with racket-mode"))
  (cond
   (racket-debug-mode
    (racket--debug-make-overlay
     (point) (1+ (point))
     'face racket-debug-break-face
     'priority 99)
    (dolist (local racket--debug-break-locals)
      (pcase-let ((`(,_src ,pos ,span ,_name ,val) local))
        (racket--debug-make-overlay
         pos (+ pos span)
         'after-string (propertize val 'face racket-debug-locals-face))))
    (pcase racket--debug-break-info
      (`(,_id after ,str)
       (let ((eol (line-end-position)))
         (racket--debug-make-overlay
          (1- eol) eol
          'after-string (propertize (concat "⇒ (values " (substring str 1))
                                    'face racket-debug-result-face)))))
    (read-only-mode 1))
   (t
    (read-only-mode -1)
    (dolist (o racket--debug-overlays)
      (delete-overlay o))
    (setq racket--debug-overlays nil))))

(defun racket--debug-make-overlay (beg end &rest props)
  (let ((o (make-overlay beg end)))
    (push o racket--debug-overlays)
    (overlay-put o 'name 'racket-debug-overlay)
    (overlay-put o 'priority 100)
    (while props
      (overlay-put o (pop props) (pop props)))
    o))

(provide 'racket-debug)

;; racket-debug.el ends here
