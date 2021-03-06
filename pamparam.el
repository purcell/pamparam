;;; pamparam.el --- Simple and fast flashcards. -*- lexical-binding: t -*-

;; Copyright (C) 2016 Oleh Krehel

;; Author: Oleh Krehel <ohwoeowho@gmail.com>
;; URL: https://github.com/abo-abo/pamparam
;; Version: 0.0.0
;; Package-Requires: ((emacs "24.3") (lispy "0.26.0") (worf "0.1.0") (hydra "0.13.4"))
;; Keywords: outlines, hypermedia, flashcards, memory

;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; An example master file is given in doc/sets/capitals/capitals.org.
;; Use `hydra-pamparam/body' as the entry point.
;; See README.org for more info.

;;; Code:

;;* Requires
(require 'worf)
(require 'lispy)
(require 'hydra)

;;* Pure
(defun pamparam-sm2 (card-stats q)
  "Determine the next iteration of CARD-STATS based on Q.

CARD-STATS is (EASE-FACTOR . INTERVALS), the result has the
same shape, with updated values.

EASE-FACTOR - the previous ease factor of the card.  All cards are
initialized with EASE-FACTOR of 2.5.  It will decrease for
difficult cards, but not below 1.3.

INTERVALS - list of integer day intervals between repetitions.

Q - the quality of the answer:
  5 - perfect response
  4 - correct response after a hesitation
  3 - correct response recalled with serious difficulty
  2 - incorrect response; where the correct one seemed easy to recall
  1 - incorrect response; the correct one remembered
  0 - complete blackout"
  (let ((EF (car card-stats))
        (intervals (cdr card-stats)))
    (setq EF (max 1.3 (+ EF 0.1 (* (- q 5) (+ 0.08 (* (- 5 q) 0.02))))))
    (if (< q 3)
        (cons EF (cons 1 intervals))
      (cons EF
            (cons
             (cond ((null intervals)
                    1)
                   ((= (car intervals) 1)
                    6)
                   (t
                    (round (* EF (car intervals)))))
             intervals)))))

;;* Card files
(defun pamparam-card-insert-score (score actual-answer)
  "Insert SCORE into the current card file."
  (goto-char (point-min))
  (outline-show-all)
  (if (re-search-forward "^\\*\\* scores" nil t)
      (outline-end-of-subtree)
    (forward-line 2)
    (insert "** scores\n")
    (backward-char))
  (when actual-answer
    (kill-new actual-answer))
  (insert (format-time-string "\n| <%Y-%m-%d> ")
          (format "| %d |" score)
          (format " %s |"
                  (or actual-answer "")))
  (org-table-align))

(defun pamparam-card-read-stats ()
  (goto-char (point-min))
  (if (re-search-forward "^\\*\\* stats\n" nil t)
      (let ((beg (point))
            (exp1 (read (current-buffer)))
            (exp2 (read (current-buffer)))
            ease-factor intervals)
        (if (and (eq (nth 0 exp1) 'setq)
                 (eq (nth 1 exp1) 'ease-factor)
                 (numberp (nth 2 exp1)))
            (setq ease-factor (nth 2 exp1))
          (error "Bad sexp %S" exp1))
        (if (and (eq (nth 0 exp2) 'setq)
                 (eq (nth 1 exp2) 'intervals))
            (setq intervals (cadr (nth 2 exp2)))
          (error "Bad sexp %S" exp2))
        (delete-region beg (point))
        (cons ease-factor intervals))
    (if (re-search-forward "^\\*\\* scores\n" nil t)
        (progn
          (outline-end-of-subtree)
          (insert "\n** stats\n")
          (list 2.5))
      (error "** scores not found"))))

(defun pamparam-card-insert-stats (stats)
  (insert (format "(setq ease-factor %f)\n" (car stats)))
  (insert (format "(setq intervals '%S)" (cdr stats))))

(defun pamparam-delete-region (beg end)
  (let ((str (buffer-substring-no-properties beg end)))
    (delete-region beg end)
    str))

(defun pamparam-save-buffer ()
  (write-file (buffer-file-name)))

(defun pamparam-card-score (score &optional actual-answer)
  (let* ((card-file (file-name-nondirectory (buffer-file-name)))
         (state (with-current-buffer (pamparam-todo-file)
                  (goto-char (point-min))
                  (search-forward card-file)
                  (goto-char (+ 2 (line-beginning-position)))
                  (buffer-substring-no-properties
                   (point)
                   (progn
                     (forward-word)
                     (point)))))
         (save-silently t))
    (cond ((string= state "REVIEW")
           (with-current-buffer (pamparam-todo-file)
             (goto-char (point-min))
             (search-forward card-file)
             (if (or (= score 5)
                     (= score 4)
                     (= score 3))
                 (let ((org-log-done nil))
                   (org-todo 'done))
               (let ((item (pamparam-delete-region
                            (line-beginning-position)
                            (1+ (line-end-position)))))
                 (goto-char (point-max))
                 (insert item)))
             (pamparam-save-buffer))
           (pamparam-save-buffer))
          ((string= state "DONE")
           (if (y-or-n-p "Card already done today.  Re-rate? ")
               (pamparam--card-score score t actual-answer)
             (user-error "This card is already done today")))
          ((string= state "TODO")
           (pamparam--card-score score nil actual-answer))
          (t
           (user-error "Unexpected state: %s" state)))
    (outline-show-all)))

(defun pamparam--todo-from-file (card-file)
  (if (string-match "\\`\\([^-]+\\)-" card-file)
      (format
       "* TODO [[file:cards/%s/%s][%s]]\n"
       (substring card-file 0 2)
       card-file
       (match-string 1 card-file))
    (error "Unexpected file name")))

(defun pamparam--card-score (score &optional already-done actual-answer)
  (let ((card-file (file-name-nondirectory (buffer-file-name)))
        stats
        new-interval)
    (save-excursion
      (pamparam-card-insert-score score actual-answer)
      (setq stats (pamparam-card-read-stats))
      (setq stats (pamparam-sm2 stats score))
      (pamparam-card-insert-stats stats)
      (setq new-interval (nth 1 stats))
      (unless already-done
        (let* ((todo-entry (pamparam--todo-from-file card-file))
               str)
          (with-current-buffer (pamparam-todo-file)
            (goto-char (point-min))
            (when (search-forward card-file)
              (if (memq score '(4 5))
                  (progn
                    (beginning-of-line)
                    (if (looking-at "\\* \\(TODO\\|REVIEW\\)")
                        (replace-match "DONE" nil nil nil 1)
                      (error "Unexpected")))
                (setq str (buffer-substring-no-properties
                           (+ 7 (line-beginning-position))
                           (1+ (line-end-position))))
                (delete-region
                 (line-beginning-position)
                 (1+ (line-end-position)))
                (goto-char (point-max))
                (insert "* REVIEW " str))
              (pamparam-save-buffer)))
          (with-current-buffer (pamparam-todo-file new-interval)
            (goto-char (point-min))
            (unless (search-forward todo-entry nil t)
              (goto-char (point-max))
              (insert todo-entry)
              (pamparam-save-buffer))
            (kill-buffer))))
      (pamparam-save-buffer))))

(defvar-local pamparam-card-answer-validate-p nil)

(defun pamparam-card-answer ()
  "Answer the current card.
Enter the answer at point, then press \".\" to validate."
  (goto-char (point-min))
  (when (re-search-forward "^\\* m$" nil t)
    (delete-region (point-min) (match-beginning 0)))
  (goto-char (point-min))
  (insert "* \n")
  (goto-char 3)
  (setq pamparam-card-answer-validate-p t))

(defvar pamparam-is-redo nil)

(defun pamparam-card-validate-maybe (&optional arg)
  "Validate the given answer and score the current card.

The given answer is the text between the card's first heading and
point."
  (interactive "p")
  (if pamparam-card-answer-validate-p
      (let ((tans (save-excursion
                    (goto-char (point-max))
                    (re-search-backward "^\\*")
                    (beginning-of-line 2)
                    (buffer-substring-no-properties
                     (point)
                     (1- (point-max)))))
            (actual-answer (buffer-substring-no-properties
                            (+ (line-beginning-position) 2)
                            (line-end-position))))
        (delete-region (point-min)
                       (1+ (line-end-position)))
        (setq pamparam-card-answer-validate-p nil)
        (if (pamparam-equal actual-answer tans)
            (if (save-excursion
                  (goto-char (point-max))
                  (re-search-backward "^\\* ")
                  (overlays-in (point) (point-max)))
                (if pamparam-is-redo
                    (pamparam-card-score 4)
                  (pamparam-card-score 5))
              (pamparam-card-score 3))
          (pamparam-card-score 0 actual-answer)))
    (self-insert-command arg)))

;;* Equivalence testing
(defvar pamparam-equiv-hash (make-hash-table :test 'equal))

(defvar pamparam-equiv-classes '(("we" "wij")
                            ("je" "jij")
                            ("ze" "zij")
                            ("u" "jij")
                            ("dichtbij" "vlakbij")
                            ("test" "toets")))

(defun pamparam-make-equivalent (a b)
  (puthash a b pamparam-equiv-hash)
  (puthash b b pamparam-equiv-hash))

(dolist (c pamparam-equiv-classes)
  (pamparam-make-equivalent (car c) (cadr c)))

(defun pamparam-equal (sa sb)
  "Check if the answer SA matches the question SB.
When SB has multiple lines, SA may match one of them."
  (if (string-match-p "\n" sb)
      (let ((sbl (split-string sb "\n" t))
            res)
        (while (and (null res) (setq sb (pop sbl)))
          (setq res (pamparam-equal-single sa sb)))
        res)
    (pamparam-equal-single sa sb)))

(defun pamparam-equal-single (sa sb)
  "Check if SA matches SB."
  (let ((lista (pamparam-sloppy sa))
        (listb (pamparam-sloppy sb))
        (res t)
        a b
        ah)
    (while (and res lista)
      (setq a (pop lista))
      (setq b (pop listb))
      (unless (or (string= a b)
                  (and (setq ah (gethash a pamparam-equiv-hash))
                       (equal ah
                              (gethash b pamparam-equiv-hash))))
        (setq res nil)))
    (and res (null listb))))

(defun pamparam-sloppy (str)
  (mapcar #'downcase
          (split-string str "[.,?! ]" t)))

(defvar pamparam-alist
  '(("/home/oleh/Dropbox/org/wiki/dutch.org" . "/home/oleh/Dropbox/source/site-lisp/git/dutch.pam"))
  "Map a master file to the corresponding repository.
Otherwise, the repository will be in the same directory as the master file.")

(defvar pamparam-load-file-name (or load-file-name
                               (buffer-file-name)))

(defvar pamparam-path (expand-file-name
                  "doc/sets/capitals/capitals.pam"
                  (file-name-directory pamparam-load-file-name))
  "Point to a default repository. In case you call `pamparam-drill'
while not in any repo, this repo will be selected.")

;;* Schedule files
(defun pamparam-repo-directory (file)
  "Return the Git repository that corresponds to FILE."
  (or (cdr (assoc file pamparam-alist))
      (expand-file-name
       (concat
        (file-name-sans-extension
         (file-name-nondirectory
          file))
        ".pam/"))))

(defvar pamparam-new-cards-per-day 75)

(defun pamparam-card-delete (file)
  "Delete the card in FILE.
When called interactively, delete the card in the current buffer."
  (interactive (list (buffer-file-name)))
  (when (and (file-exists-p file)
             (y-or-n-p
              (format "Really delete %s? "
                      (file-name-nondirectory file))))
    (delete-file file)
    (when (string= (buffer-file-name) file)
      (kill-buffer))
    (pamparam--update-card
     (file-name-nondirectory file)
     nil)))

(defun pamparam--update-card (prev-file new-entry)
  (let ((prev-scheduled (pamparam-cmd-to-list (format "git grep %s" (shell-quote-argument prev-file))))
        (save-silently t))
    (dolist (prev prev-scheduled)
      (unless (string-match "\\`\\([^:]+\\):.*\\[\\[file:cards/\\(.*\\)\\]\\[.*\\]\\'" prev)
        (user-error "Bad scheduled item: %s" prev))
      (let ((schedule-file
             (expand-file-name
              (match-string 1 prev)))
            (entry (match-string 2 prev)))
        (with-temp-buffer
          (insert-file-contents schedule-file)
          (when (re-search-forward entry nil t)
            (if new-entry
                (replace-match new-entry)
              (delete-region
               (line-beginning-position)
               (1+ (line-end-position)))))
          (write-file schedule-file))))))

(defvar pamparam-hash-card-name->file nil)
(defvar pamparam-hash-card-body->file nil)

(defun pamparam-cmd-to-list (cmd &optional directory)
  (let ((default-directory (or directory default-directory)))
    (split-string
     (shell-command-to-string cmd)
     "\n" t)))

(defun pamparam-cards (repo-dir)
  (pamparam-cmd-to-list
   "git ls-files cards/"
   repo-dir))

(defun pamparam-visited-cards (repo-dir)
  (pamparam-cmd-to-list
   "git grep --files-with-matches '^\\*\\* scores'"
   repo-dir))

(defun pamparam-unvisited-cards (repo-dir)
  (pamparam-cmd-to-list
   "git grep --files-without-match '^\\*\\* scores' | grep cards/"
   repo-dir))

(defun pamparam-pile (repo-dir)
  "Pile up all unvisited cards into a single file."
  (let ((unvisited-cards (pamparam-unvisited-cards repo-dir))
        (schedule-files (pamparam-cmd-to-list "git ls-files --full-name pamparam-*-[0-9][0-9].org"))
        (save-silently t))
    (dolist (sf schedule-files)
      (with-current-buffer (find-file (expand-file-name sf repo-dir))
        (dolist (card unvisited-cards)
          (goto-char (point-min))
          (while (search-forward card nil t)
            (delete-region (line-beginning-position) (1+ (line-end-position)))))
        (pamparam-save-buffer)
        (kill-buffer)))
    (with-current-buffer (find-file (expand-file-name "pampile.org" repo-dir))
      (delete-region (point-min) (point-max))
      (dolist (card unvisited-cards)
        (insert (pamparam--todo-from-file (file-name-nondirectory card))))
      (pamparam-save-buffer)
      (kill-buffer))))

(defun pamparam-pull (arg &optional buffer)
  "Pull ARG cards into BUFFER.
When called interactively, use today's schedule file."
  (interactive
   (list (read-number "how many cards: ")
         (pamparam-todo-file)))
  (let ((save-silently t)
        cards)
    (setq arg (min 100 arg))
    (switch-to-buffer buffer)
    (with-current-buffer (find-file-noselect
                          (expand-file-name "pampile.org"))
      (goto-char (point-min))
      (end-of-line arg)
      (setq cards (pamparam-delete-region (point-min)
                                     (min (1+ (point))
                                          (point-max))))
      (pamparam-save-buffer)
      (kill-buffer))
    (pamparam-goto-schedule-part)
    (insert cards)
    (pamparam-save-buffer)))

(defun pamparam-goto-schedule-part ()
  (goto-char (point-min))
  (if (re-search-forward "^\\*" nil t)
      (goto-char (match-beginning 0))
    (goto-char (point-max))))

(defun pamparam--recompute-git-cards (repo-dir)
  (setq pamparam-hash-card-name->file (make-hash-table :test 'equal))
  (setq pamparam-hash-card-body->file (make-hash-table :test 'equal))
  (let ((git-files (pamparam-cards repo-dir)))
    (dolist (gf git-files)
      (if (string-match "\\`cards/[0-9a-f]\\{2\\}/\\([^-]+\\)-\\([^.]+\\)\\.org\\'" gf)
          (progn
            (puthash (match-string 1 gf) gf pamparam-hash-card-name->file)
            (puthash (match-string 2 gf) gf pamparam-hash-card-body->file))
        (error "Unexpected file name %s" gf)))))

(defun pamparam--replace-card (_card-front _card-body repo-dir card-file prev-file)
  (let ((old-metadata
         (with-temp-buffer
           (insert-file-contents (expand-file-name prev-file repo-dir))
           (goto-char (point-min))
           (when (looking-at "\\* m$")
             (outline-end-of-subtree)
             (buffer-substring-no-properties
              (point-min)
              (1+ (point)))))))
    (delete-file (expand-file-name prev-file repo-dir))
    (let ((default-directory repo-dir)
          (fnn (file-name-nondirectory card-file)))
      (pamparam--update-card prev-file (concat (substring fnn 0 2) "/" fnn)))
    old-metadata))

(defun pamparam-update-card (card-front card-body repo-dir)
  (let* ((card-front-id (md5 card-front))
         (card-body-id (md5 card-body))
         (prev-file
          (or
           (gethash card-front-id pamparam-hash-card-name->file)
           (gethash card-body-id pamparam-hash-card-body->file)))
         (subdir (substring card-front-id 0 2))
         (card-file
          (concat
           "cards/" subdir "/" card-front-id "-" card-body-id ".org"))
         (full-card-file (expand-file-name card-file repo-dir))
         (metadata nil))
    (cond ((null prev-file))
          ((string= card-file prev-file))
          (t
           (when (file-exists-p (expand-file-name prev-file repo-dir))
             (setq metadata (pamparam--replace-card
                             card-front card-body repo-dir card-file prev-file)))))
    (unless (file-exists-p (expand-file-name card-file repo-dir))
      (let* ((txt
              (replace-regexp-in-string
               "'" "'\\''"
               (format "%s* %s\\n%s"
                       (or metadata "* m\\n#+STARTUP: content\\n")
                       card-front
                       card-body)
               t t))
             (cmd (format "mkdir -p %s && echo -e %s > %s"
                          (shell-quote-argument (file-name-directory full-card-file))
                          (shell-quote-argument txt)
                          (shell-quote-argument full-card-file))))
        (if (= 0 (call-process-shell-command cmd))
            (cons (if metadata
                      'update
                    'new)
                  card-file)
          (error "Command failed: %s" cmd))))))

(defconst pamparam-card-source-regexp "^\\* .*:cards:")

(defun pamparam-sync ()
  "Synchronize the current `org-mode' master file to the cards repository.

Create the cards repository if it doesn't exist.

Each card is uniquely identifiable by either its front or its
back.  So if you want to modify both the front and the back, first
modify the front, call `pamparam-sync', then modify the back and call
`pamparam-sync' again.  Otherwise, there's no way to \"connect\" the
new card to the old one, and the old card will remain in the
repository, while the new card will start with empty metadata."
  (interactive)
  (unless (eq major-mode 'org-mode)
    (error "Must be in `org-mode' file"))
  (let ((repo-dir
         (pamparam-repo-directory (buffer-file-name)))
        (repo-is-new nil)
        (make-backup-files nil))
    (if (file-exists-p repo-dir)
        (unless (file-directory-p repo-dir)
          (error "%s must be a directory" repo-dir))
      (make-directory repo-dir)
      (let ((default-directory repo-dir))
        (shell-command "git init")
        (make-directory "cards/"))
      (setq repo-is-new t))
    (pamparam--recompute-git-cards repo-dir)
    (let ((old-point (point))
          (processed-headings nil)
          (new-cards nil)
          (updated-cards nil))
      (goto-char (point-min))
      (unless (re-search-forward pamparam-card-source-regexp nil t)
        (error "No outlines with the :cards: tag found"))
      (beginning-of-line)
      (while (re-search-forward pamparam-card-source-regexp nil t)
        (lispy-destructuring-setq (processed-headings new-cards updated-cards)
                                  (pamparam-sync-current-outline
                                   processed-headings new-cards updated-cards repo-dir)))
      (goto-char old-point)
      (when (or new-cards updated-cards)
        (pamparam-schedule-today
         (mapcar #'pamparam--todo-from-file new-cards)
         (find-file (expand-file-name "pampile.org" repo-dir)))
        (when repo-is-new
          nil)
        (shell-command-to-string
         (format
          "cd %s && git add . && git commit -m %s"
          (shell-quote-argument repo-dir)
          (shell-quote-argument
           (cond ((null updated-cards)
                  (format "Add %d new card(s)" (length new-cards)))
                 ((null new-cards)
                  (format "Update %d card(s)" (length updated-cards)))
                 (t
                  (format "Add %d new card(s), update %d cards"
                          (length new-cards)
                          (length updated-cards))))))))
      (message "%d new cards, %d updated, %d total"
               (length new-cards)
               (length updated-cards)
               (length processed-headings)))))

(defun pamparam-sync-current-outline (processed-headings new-cards updated-cards repo-dir)
  (let ((end (save-excursion
               (outline-end-of-subtree)
               (skip-chars-backward "\n ")
               (point))))
    (while (re-search-forward "^\\*\\{2,3\\} \\(.*\\)$" end t)
      (let* ((card-front (match-string-no-properties 1))
             (card-body (buffer-substring-no-properties
                         (1+ (point))
                         (if (re-search-forward "^\\*" end t)
                             (progn
                               (backward-char 2)
                               (point))
                           end)))
             card-info
             card-file)
        (if (member card-front processed-headings)
            (error "Duplicate heading encountered: %s" card-front)
          (push card-front processed-headings))
        (when (setq card-info (pamparam-update-card card-front card-body repo-dir))
          (setq card-file (file-name-nondirectory (cdr card-info)))
          (cond ((eq (car card-info) 'new)
                 (push card-file new-cards))
                ((eq (car card-info) 'update)
                 (push card-file updated-cards))))))
    (list processed-headings new-cards updated-cards)))

(defun pamparam-default-directory ()
  (if (string-match "^\\(.*\\.pam/\\)" default-directory)
      (expand-file-name (match-string 1 default-directory))
    pamparam-path))

(defun pamparam-kill-buffers ()
  (let* ((pdir (pamparam-default-directory))
         (cards-dir (expand-file-name "cards/" pdir)))
    (dolist (b (buffer-list))
      (when (buffer-file-name b)
        (let ((dir (file-name-directory (buffer-file-name b))))
          (when (or (equal dir cards-dir)
                    (and (equal dir pdir)
                         (not (equal (file-name-nondirectory
                                      (buffer-file-name b))
                                     (pamparam-schedule-file (current-time))))))
            (kill-buffer b)))))))

(defun pamparam-schedule-file (time)
  (let ((year (format-time-string "%Y" time))
        (current-year (format-time-string "%Y" (current-time)))
        (base (format-time-string "pamparam-%Y-%m-%d.org" time)))
    (if (string= year current-year)
        base
      (let ((dir (expand-file-name
                  year (expand-file-name "years" (pamparam-default-directory)))))
        (unless (file-exists-p dir)
          (make-directory dir t))
        (expand-file-name base dir)))))

(defun pamparam-todo-file (&optional offset)
  (setq offset (or offset 0))
  (let* ((default-directory (pamparam-default-directory))
         (todo-file (expand-file-name
                     (pamparam-schedule-file
                      (time-add
                       (current-time)
                       (days-to-time offset)))))
         (save-silently t))
    (unless (file-exists-p todo-file)
      (save-current-buffer
        (find-file todo-file)
        (insert "#+SEQ_TODO: TODO REVIEW | DONE\n")
        (when (eq offset 0)
          (pamparam-pull 10 (current-buffer))
          (message "Schedule was empty, used `pamparam-pull' for 10 cards"))
        (pamparam-save-buffer)))
    (find-file-noselect todo-file)))

(defvar pamparam-last-rechedule nil)

(defun pamparam-schedule-today (cards &optional buffer)
  (with-current-buffer (or buffer (pamparam-todo-file))
    (pamparam-goto-schedule-part)
    (dolist (card cards)
      (insert card))
    (let ((save-silently t))
      (pamparam-save-buffer))))

(defun pamparam-reschedule-maybe ()
  (let ((today (calendar-current-date)))
    (unless (and pamparam-last-rechedule
                 (<
                  (calendar-absolute-from-gregorian today)
                  (calendar-absolute-from-gregorian pamparam-last-rechedule)))
      (setq pamparam-last-rechedule today)
      (let* ((today-file (pamparam-todo-file))
             (today-file-name (file-name-nondirectory
                               (buffer-file-name today-file)))
             (pdir (file-name-directory
                    (buffer-file-name today-file)))
             (all-files (directory-files pdir nil "org$"))
             (idx (cl-position today-file-name all-files
                               :test 'equal))
             (old-files (reverse (cl-subseq all-files 0 idx))))
        (dolist (old-file old-files)
          (setq old-file (expand-file-name old-file pdir))
          (let (cards)
            (with-current-buffer (find-file-noselect old-file)
              (goto-char (point-min))
              (while (re-search-forward "^\\* \\(TODO\\|REVIEW\\) " nil t)
                (push (buffer-substring-no-properties
                       (point) (1+ (line-end-position)))
                      cards)))
            (pamparam-schedule-today (mapcar (lambda (s) (concat "* TODO " s))
                                        (nreverse cards)))
            (delete-file old-file)))))))

;;;###autoload
(defun pamparam-drill ()
  "Start a learning session.

When `default-directory' is in a *.pam repository, use that repository.
Otherwise, use the repository that `pamparam-path' points to.

See `pamparam-sync' for creating and updating a *.pam repository.

If you have no more cards scheduled for today, use `pamparam-pull'."
  (interactive)
  (pamparam-reschedule-maybe)
  (let (card-link card-file)
    (when (bound-and-true-p pamparam-card-mode)
      (when (buffer-modified-p)
        (pamparam-save-buffer))
      (kill-buffer))
    (delete-other-windows)
    (split-window-vertically)
    (pamparam-kill-buffers)
    (switch-to-buffer (pamparam-todo-file))
    (goto-char (point-min))
    (when (re-search-forward "^* \\(TODO\\|REVIEW\\) " nil t)
      (recenter 5)
      (setq card-link (buffer-substring-no-properties
                       (point) (line-end-position)))
      (beginning-of-line)
      (set-window-point (selected-window) (point)))
    (other-window 1)
    (if (null card-link)
        (message "%d cards learned/reviewed today. Well done!"
                 (cl-count-if
                  (lambda (x) (string-match "^\\* DONE" x))
                  (split-string (with-current-buffer (pamparam-todo-file)
                                  (buffer-string)) "\n")))
      (unless (string-match "\\`\\[\\[file:\\([^]]+\\)\\]\\[.*\\]\\]\\'" card-link)
        (error "Bad entry in %s: %s" (pamparam-todo-file) card-link))
      (setq card-file (match-string 1 card-link))
      (switch-to-buffer
       (find-file-noselect
        (expand-file-name card-file (pamparam-default-directory))))
      (pamparam-card-mode))))

(defun pamparam-commit ()
  "Commit the current progress using Git."
  (interactive)
  (let* ((default-directory (pamparam-default-directory))
         (status (pamparam-cmd-to-list "git status"))
         (card-count
          (cl-count-if
           (lambda (s)
             (or (string-match "modified.*cards/" s)
                 (string-match "new file.*cards/" s)))
           status))
         (card-str (if (= card-count 1)
                       "card"
                     "cards")))
    (message
     (replace-regexp-in-string
      "%" "%%"
      (shell-command-to-string
       (format
        "git add . && git commit -m 'Do %s %s'"
        card-count card-str))))))

(defun pamparam-unschedule-card (card-file)
  "Unschedule CARD-FILE everywhere and schedule it for today."
  (let* ((repo-dir (locate-dominating-file card-file ".git"))
         (s-files (pamparam-cmd-to-list (format "git add . && git grep --files-with-matches %s" (shell-quote-argument card-file))
                                        repo-dir)))
    (dolist (file s-files)
      (with-current-buffer (find-file-noselect (expand-file-name file repo-dir))
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward card-file nil t)
            (delete-region (line-beginning-position)
                           (1+ (line-end-position))))
          (let ((save-silently t))
            (pamparam-save-buffer)))
        (unless (equal (current-buffer) (pamparam-todo-file))
          (kill-buffer))))
    (with-current-buffer (pamparam-todo-file)
      (pamparam-goto-schedule-part)
      (if (re-search-forward "^\\* \\(TODO\\|REVIEW\\)" nil t)
          (goto-char (match-beginning 0))
        (goto-char (point-max)))
      (insert (pamparam--todo-from-file card-file)))))

(defun pamparam-card-redo ()
  "Redo the current card without penalty."
  (interactive)
  (if (string-match-p "cards/.*org\\'" (buffer-file-name))
      (let ((fname (buffer-file-name)))
        (pamparam-save-buffer)
        (pamparam-cmd-to-list (format "git checkout -- %s" (shell-quote-argument fname)))
        (revert-buffer nil t nil)
        (pamparam-unschedule-card (file-name-nondirectory fname))
        (setq-local pamparam-is-redo t)
        (pamparam-card-mode))
    (user-error "Applies only to card files")))

;;* `pamparam-card-mode'
(defvar pamparam-card-mode-map
  (let ((map (make-sparse-keymap)))
    (worf-define-key map (kbd "q") 'bury-buffer)
    (worf-define-key map (kbd "R") 'pamparam-card-redo
                     :break t)
    (worf-define-key map (kbd "n") 'pamparam-drill
                     :break t)
    (worf-define-key map (kbd "D") 'pamparam-card-delete)
    (define-key map (kbd ".") 'pamparam-card-validate-maybe)
    map))

(define-minor-mode pamparam-card-mode
  "Minor mode for Pam cards.

\\{pamparam-card-mode-map}"
  :lighter " p"
  (when pamparam-card-mode
    (if (eq major-mode 'org-mode)
        (progn
          (setq org-cycle-global-status 'contents)
          (goto-char (point-min))
          (pamparam-card-answer))
      (pamparam-card-mode -1))))

(lispy-raise-minor-mode 'pamparam-card-mode)

;;* `hydra-pamparam'
(defhydra hydra-pamparam (:exit t)
  "pam"
  ("d" pamparam-drill "drill")
  ("s" pamparam-sync "sync")
  ("p" pamparam-pull "pull")
  ("c" pamparam-commit "commit")
  ("q" nil "quit"))
(hydra-set-property 'hydra-pamparam :verbosity 1)

(provide 'pamparam)

;;; pamparam.el ends here
