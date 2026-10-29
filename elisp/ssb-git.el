;;; ssb-git.el --- Git repos, issues and pull requests on SSB  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-2.0-only
;;
;; Copyright (C) 2026 Commonwealth of Scuttlebutt

;;; Commentary:
;;
;; The forge half of ssb_git, for Emacs.  Git itself is used as usual —
;; from the shell, from Emacs's built-in VC (`C-x v P' pushes), or any
;; other front end: clone, fetch and push work on ssb:// URLs through
;; git-remote-ssb.  This is everything git has no word for: the repos the
;; node knows, a repo's branches and pushes, and its issues and pull
;; requests.  The only git commands it runs are a clone and checking out
;; a pull request.
;;
;; It runs on maxbutt: the same Distel connection to the same erlbutt
;; node (`ssb-node'), maxbutt's feed and thread views, and the node-side
;; functions in ssb_git_emacs, which the ssb_git plugin provides.
;;
;;   (add-to-list 'load-path "<release>/plugins/ssb_git/elisp")
;;   (require 'ssb-git)
;;
;; M-x ssb-git-repos — every repo the node knows (C-u: only yours).
;;   RET  open the repo          g  refresh       m  toggle yours / all
;;
;; A repo buffer:
;;   i  issues     P  pull requests     N  new issue     R  new pull request
;;   w  copy the repo's ssb:// URL      C  clone it
;;   RET / t on a push  open its message as a thread
;;   f  browse the feed of the author at point
;;
;; An issue list:
;;   RET  open      s  cycle open / closed / all      N  new      g  refresh
;;
;; An issue or pull request:
;;   r  comment     x  close or reopen     o  check out a pull request
;;   t  the comment thread in maxbutt's thread view   f  author's feed
;;
;; Compose buffers send with C-c C-c and cancel with C-c C-k.

;;; Code:

(require 'ssb-feed)
(require 'tabulated-list)
(require 'subr-x)

(defgroup ssb-git nil
  "Git repositories, issues and pull requests on SSB."
  :group 'maxbutt)

(defcustom ssb-git-bin-directory
  (when load-file-name
    (let ((bin (expand-file-name "../bin" (file-name-directory load-file-name))))
      (and (file-directory-p bin) bin)))
  "Directory holding git-remote-ssb, put first on PATH for the git runs here.
By default the plugin's bin/, beside the elisp/ this file was loaded
from, so a clone works even when Emacs's PATH (on macOS, launchd's, not
the shell's) does not have the commands on it.  nil leaves PATH alone."
  :type '(choice (const :tag "PATH as it is" nil) directory)
  :group 'ssb-git)

;;; Terms from the node

(defun ssb-git--get (map key)
  "KEY's value in MAP, a node map (an elisp hash table), or nil."
  (and (hash-table-p map) (gethash key map)))

(defun ssb-git--str (s)
  "S, a binary from the node, as a string; nil stays nil.
erlext decodes binaries as UTF-8 (maxbutt since its UTF-8 fix)."
  (and (stringp s) s))

(defun ssb-git--bin (s)
  "S as an Erlang binary; erlext sends it as UTF-8."
  (erl-binary s))

(defun ssb-git--true (v)
  "Whether V is the Erlang atom true."
  (eq v 'true))

(defun ssb-git--date (ms)
  "MS, milliseconds since the epoch, as a date."
  (if (numberp ms) (format-time-string "%Y-%m-%d" (/ ms 1000.0)) ""))

(defun ssb-git--who (map)
  "The profile name of MAP's author, else a short id."
  (or (ssb-git--str (ssb-git--get map 'author_name))
      (ssb--short-id (ssb-git--get map 'author))))

(defun ssb-git--ok (reply)
  "The value in REPLY if it is {ok, Value}, else signal the error."
  (if (and (vectorp reply) (eq (elt reply 0) 'ok))
      (elt reply 1)
    (user-error "ssb-git: %S" reply)))

(defun ssb-git--call (fun args callback)
  "Call ssb_git_emacs:FUN with ARGS on `ssb-node'; CALLBACK gets the reply."
  (erl-rpc (lambda (reply)
             (if (and (vectorp reply) (eq (elt reply 0) 'badrpc))
                 (message "ssb-git: is the ssb_git plugin running in %s? %S"
                          ssb-node reply)
               (funcall callback reply)))
           nil ssb-node 'ssb_git_emacs fun args))

(defun ssb-git--url (id)
  "The ssb:// URL of repo ID."
  (concat "ssb://" id))

(defun ssb-git--title (map)
  "MAP's title, or a placeholder."
  (or (ssb-git--str (ssb-git--get map 'title)) "(untitled)"))

(defun ssb-git--repo-label (map)
  "A repo's name; else, dimmed, a name someone else gave it; else its short id.
Only the repo's author's names count (see `ssb-git--insert-names')."
  (or (ssb-git--str (ssb-git--get map 'name))
      (when-let* ((other (ssb-git--str (ssb-git--get map 'other_name))))
        (propertize other 'face 'shadow))
      (ssb--short-id (ssb-git--get map 'id))))

(defun ssb-git--insert-names (r)
  "Insert every name repo R has been given, if any is not its current one."
  (let ((names (ssb-git--get r 'names))
        (current (ssb-git--str (ssb-git--get r 'name))))
    (when (seq-some (lambda (n) (not (equal (ssb-git--str (ssb-git--get n 'name)) current)))
                    names)
      (insert "named\n")
      (dolist (n names)
        (let ((s (point)))
          (insert (format "  %s  %-24s by %s%s\n"
                          (ssb-git--date (ssb-git--get n 'ts))
                          (truncate-string-to-width (ssb-git--str (ssb-git--get n 'name)) 24)
                          (ssb-git--who n)
                          (if (ssb-git--true (ssb-git--get n 'counted)) ""
                            (propertize "   (not counted: not the repo's author)"
                                        'face 'shadow))))
          (put-text-property s (point) 'ssb-author (ssb-git--get n 'author)))))))

(defmacro ssb-git--with-buffer (name mode &rest body)
  "Erase buffer NAME, run BODY in it, switch to MODE, and show it."
  (declare (indent 2))
  `(let ((buf (get-buffer-create ,name)))
     (with-current-buffer buf
       (let ((inhibit-read-only t)
             (pos (point)))
         (erase-buffer)
         (unless (derived-mode-p ,mode) (funcall ,mode))
         ,@body
         (goto-char (min pos (point-max)))))
     (pop-to-buffer-same-window buf)
     buf))

;;; Buffer state

(defvar-local ssb-git--issues-repo nil "The repo whose issues this lists.")
(defvar-local ssb-git--issues-kind 'issue "`issue' or `pull_request'.")
(defvar-local ssb-git--issues-state 'open "`open', `closed' or `all'.")
(defvar-local ssb-git--repo nil
  "The repo this buffer shows: a node map.")
(defvar-local ssb-git--issue nil "The issue this buffer shows: a node map.")

;;; Repos

(defvar-local ssb-git--repos-which 'all
  "Which repos this list shows: `all' or `mine'.")

;;;###autoload
(defun ssb-git-repos (&optional mine)
  "List the git repos the node knows, most recently active first.
With a prefix argument MINE, only the repos you created."
  (interactive "P")
  (let ((which (if mine 'mine 'all)))
    (ssb-git--call 'repos (list which)
                   (lambda (repos) (ssb-git--show-repos repos which)))))

(defun ssb-git--show-repos (repos which)
  (ssb-git--with-buffer "*ssb-git repos*" #'ssb-git-repos-mode
    (setq ssb-git--repos-which which)
    (setq tabulated-list-entries
          (mapcar (lambda (r)
                    (let ((oi (ssb-git--get r 'open_issues))
                          (op (ssb-git--get r 'open_prs)))
                      (list (ssb-git--get r 'id)
                            (vector (ssb-git--date (or (ssb-git--get r 'pushed)
                                                       (ssb-git--get r 'created)))
                                    (ssb-git--repo-label r)
                                    (ssb-git--who r)
                                    (if (and oi (> oi 0)) (number-to-string oi) "")
                                    (if (and op (> op 0)) (number-to-string op) "")))))
                  repos))
    (tabulated-list-print t)
    (setq header-line-format
          (concat (format " %d repos%s   " (length repos)
                          (if (eq which 'mine) " (yours)" ""))
                  (substitute-command-keys "\\<ssb-git-repos-mode-map>\\[ssb-git-open-repo] open  \\[ssb-git-repos-toggle-mine] yours/all  \\[revert-buffer] refresh")))))

(define-derived-mode ssb-git-repos-mode tabulated-list-mode "SSB-Git-Repos"
  "Git repos known to the node.
\\{ssb-git-repos-mode-map}"
  (setq tabulated-list-format [("Active" 10 t) ("Repo" 30 t) ("Author" 20 t)
                               ("Issues" 6 t :right-align t) ("PRs" 4 t :right-align t)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'ssb-git--revert-repos nil t)
  (tabulated-list-init-header))

(defun ssb-git--revert-repos ()
  (ssb-git-repos (eq ssb-git--repos-which 'mine)))

(defun ssb-git-repos-toggle-mine ()
  "Switch between all repos and only yours."
  (interactive)
  (ssb-git-repos (not (eq ssb-git--repos-which 'mine))))

(defun ssb-git-open-repo ()
  "Open the repo at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (if id (ssb-git-repo id) (user-error "No repo at point"))))

(let ((map ssb-git-repos-mode-map))
  (define-key map (kbd "RET") #'ssb-git-open-repo)
  (define-key map (kbd "m")   #'ssb-git-repos-toggle-mine))

;;; A repo

;;;###autoload
(defun ssb-git-repo (id)
  "Show repo ID: its branches and recent pushes.
ID is a git-repo message id, with or without the ssb:// prefix."
  (interactive "sRepo (ssb://%… or %…): ")
  (let ((id (string-remove-prefix "ssb://" (string-trim id))))
    (ssb-git--call 'repo (list (ssb-git--bin id))
                   (lambda (reply) (ssb-git--show-repo (ssb-git--ok reply))))))

(defun ssb-git--show-repo (r)
  (ssb-git--with-buffer (format "*ssb-git %s*" (ssb-git--repo-label r)) #'ssb-git-repo-mode
    (setq ssb-git--repo r)
    (let ((id (ssb-git--get r 'id)))
      (insert (propertize (ssb-git--repo-label r) 'face 'bold) "\n"
              (ssb-git--url id) "\n")
      (ssb-git--insert-author r (format "created %s by " (ssb-git--date (ssb-git--get r 'created))))
      (when-let* ((up (ssb-git--get r 'upstream)))
        (insert "fork of " (ssb-git--url up) "\n"))
      (ssb-git--insert-names r)
      (insert (format "%d open issues, %d open pull requests\n\n"
                      (or (ssb-git--get r 'open_issues) 0)
                      (or (ssb-git--get r 'open_prs) 0)))
      (insert (propertize "Branches" 'face 'bold) "\n")
      (let ((head (ssb-git--str (ssb-git--get r 'head)))
            (refs (ssb-git--get r 'refs)))
        (if (null refs)
            (insert "  (none yet: nothing has been pushed)\n")
          (dolist (ref refs)
            (let ((name (ssb-git--str (ssb-git--get ref 'name)))
                  (conflict (ssb-git--str (ssb-git--get ref 'conflict))))
              (insert (format "  %s %s  %s%s\n"
                              (if (equal name head) "*" " ")
                              (substring (ssb-git--get ref 'hash) 0 7)
                              name
                              (if conflict
                                  (propertize (format "   conflicts with %s" conflict)
                                              'face 'warning)
                                "")))))))
      (insert "\n" (propertize "Recent pushes" 'face 'bold) "\n")
      (dolist (u (ssb-git--get r 'updates))
        (let ((start (point)))
          (insert (format "%s  %-18s %s\n"
                          (ssb-git--date (ssb-git--get u 'ts))
                          (truncate-string-to-width (ssb-git--who u) 18)
                          (mapconcat (lambda (ref)
                                       (format "%s%s"
                                               (string-remove-prefix
                                                "refs/heads/" (ssb-git--str (ssb-git--get ref 'name)))
                                               (if (ssb-git--get ref 'hash) "" " (deleted)")))
                                     (ssb-git--get u 'refs) ", ")))
          (dolist (c (ssb-git--get u 'commits))
            (insert (format "            %s %s\n" (substring (ssb-git--get c 'sha1) 0 7)
                            (or (ssb-git--str (ssb-git--get c 'title)) ""))))
          (let ((more (ssb-git--get u 'commits_more)))
            (when (and more (> more 0))
              (insert (format "            … and %d more commits\n" more))))
          (add-text-properties start (point)
                               (list 'ssb-key (ssb-git--get u 'key)
                                     'ssb-author (ssb-git--get u 'author))))))
    (goto-char (point-min))))

(defun ssb-git--insert-author (map prefix)
  "Insert PREFIX and MAP's author, the name carrying `ssb-author' for f."
  (insert prefix)
  (let ((start (point)))
    (insert (ssb-git--who map))
    (put-text-property start (point) 'ssb-author (ssb-git--get map 'author)))
  (insert "\n"))

(define-derived-mode ssb-git-repo-mode special-mode "SSB-Git-Repo"
  "A git repo on SSB.
\\{ssb-git-repo-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _) (ssb-git-repo (ssb-git--get ssb-git--repo 'id)))))

(defun ssb-git--repo-id ()
  (or (ssb-git--get ssb-git--repo 'id)
      ssb-git--issues-repo
      (user-error "Not in a repo buffer")))

(defun ssb-git-copy-url ()
  "Copy this repo's ssb:// URL."
  (interactive)
  (let ((url (ssb-git--url (ssb-git--repo-id))))
    (kill-new url)
    (message "Copied %s" url)))

(defun ssb-git-clone (dir)
  "Clone this repo into DIR."
  (interactive
   (list (read-directory-name "Clone into: " nil nil nil
                              (ssb-git--safe-name (ssb-git--repo-label ssb-git--repo)))))
  (ssb-git--run-git (list "clone" (ssb-git--url (ssb-git--repo-id)) (expand-file-name dir))
                    default-directory
                    (format "Cloned into %s" dir)))

(defun ssb-git--safe-name (s)
  "S made safe for a directory or branch name."
  (replace-regexp-in-string "[^A-Za-z0-9._-]+" "-" s))

(defun ssb-git--run-git (args dir done &optional then)
  "Run git with ARGS in DIR, output in *ssb-git output*; say DONE, run THEN."
  (let* ((buf (get-buffer-create "*ssb-git output*"))
         (default-directory dir)
         (process-environment
          (if ssb-git-bin-directory
              (cons (concat "PATH=" (expand-file-name ssb-git-bin-directory)
                            path-separator (or (getenv "PATH") ""))
                    process-environment)
            process-environment)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "\n$ git " (string-join args " ") "\n")))
    (message "git %s …" (car args))
    (make-process
     :name "ssb-git" :buffer buf :command (cons "git" args)
     :sentinel (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (if (zerop (process-exit-status proc))
                       (progn (message "%s" done) (when then (funcall then)))
                     (display-buffer buf)
                     (message "git %s failed; see *ssb-git output*" (car args))))))))

(let ((map ssb-git-repo-mode-map))
  (define-key map (kbd "i")   #'ssb-git-issues)
  (define-key map (kbd "P")   #'ssb-git-pull-requests)
  (define-key map (kbd "N")   #'ssb-git-new-issue)
  (define-key map (kbd "R")   #'ssb-git-new-pull-request)
  (define-key map (kbd "w")   #'ssb-git-copy-url)
  (define-key map (kbd "C")   #'ssb-git-clone)
  (define-key map (kbd "RET") #'ssb-show-thread)
  (define-key map (kbd "t")   #'ssb-show-thread)
  (define-key map (kbd "f")   #'ssb-browse-author-feed)
  (define-key map (kbd "n")   #'ssb-git-next-item)
  (define-key map (kbd "p")   #'ssb-git-prev-item))

(defun ssb-git-next-item ()
  "Move to the next push, comment or change."
  (interactive)
  (let ((here (get-text-property (point) 'ssb-key)))
    (goto-char (or (next-single-property-change (point) 'ssb-key) (point)))
    (when (and (not (get-text-property (point) 'ssb-key)) here)
      (goto-char (or (next-single-property-change (point) 'ssb-key) (point))))))

(defun ssb-git-prev-item ()
  "Move to the previous push, comment or change."
  (interactive)
  (goto-char (or (previous-single-property-change (point) 'ssb-key) (point-min)))
  (unless (get-text-property (point) 'ssb-key)
    (goto-char (or (previous-single-property-change (point) 'ssb-key) (point-min))))
  (beginning-of-line))

;;; Issue lists


(defun ssb-git-issues (&optional repo kind state)
  "List REPO's issues (KIND `pull_request' for pull requests) in STATE."
  (interactive)
  (let ((repo (or repo (ssb-git--repo-id)))
        (kind (or kind 'issue))
        (state (or state 'open)))
    (ssb-git--call 'issues (list (ssb-git--bin repo) kind state)
                   (lambda (issues)
                     (ssb-git--show-issues issues repo kind state)))))

(defun ssb-git-pull-requests ()
  "List this repo's open pull requests."
  (interactive)
  (ssb-git-issues (ssb-git--repo-id) 'pull_request 'open))

(defun ssb-git--state-label (i)
  (cond ((ssb-git--true (ssb-git--get i 'open)) "open")
        ((ssb-git--true (ssb-git--get i 'merged)) "merged")
        (t "closed")))

(defun ssb-git--show-issues (issues repo kind state)
  (ssb-git--with-buffer (format "*ssb-git %s %s*" (ssb--short-id repo)
                                (if (eq kind 'pull_request) "pull requests" "issues"))
      #'ssb-git-issues-mode
    (setq ssb-git--issues-repo repo
          ssb-git--issues-kind kind
          ssb-git--issues-state state)
    (setq tabulated-list-entries
          (mapcar (lambda (i)
                    (list (ssb-git--get i 'id)
                          (vector (ssb-git--state-label i)
                                  (ssb-git--date (ssb-git--get i 'ts))
                                  (ssb-git--title i)
                                  (ssb-git--who i))))
                  issues))
    (tabulated-list-print t)
    (setq header-line-format
          (format " %d %s %s   %s" (length issues) state
                  (if (eq kind 'pull_request) "pull requests" "issues")
                  (substitute-command-keys "\\<ssb-git-issues-mode-map>\\[ssb-git-open-issue] open  \\[ssb-git-issues-cycle-state] open/closed/all  \\[ssb-git-new-issue] new")))))

(define-derived-mode ssb-git-issues-mode tabulated-list-mode "SSB-Git-Issues"
  "Issues or pull requests of a repo.
\\{ssb-git-issues-mode-map}"
  (setq tabulated-list-format [("State" 7 t) ("Date" 10 t) ("Title" 60 t) ("Author" 20 t)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'ssb-git--revert-issues nil t)
  (tabulated-list-init-header))

(defun ssb-git--revert-issues ()
  (ssb-git-issues ssb-git--issues-repo ssb-git--issues-kind ssb-git--issues-state))

(defun ssb-git-issues-cycle-state ()
  "Show open, then closed, then all."
  (interactive)
  (ssb-git-issues ssb-git--issues-repo ssb-git--issues-kind
                  (pcase ssb-git--issues-state ('open 'closed) ('closed 'all) (_ 'open))))

(defun ssb-git-open-issue ()
  "Open the issue or pull request at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (if id (ssb-git-issue id) (user-error "Nothing at point"))))

(let ((map ssb-git-issues-mode-map))
  (define-key map (kbd "RET") #'ssb-git-open-issue)
  (define-key map (kbd "s")   #'ssb-git-issues-cycle-state)
  (define-key map (kbd "N")   #'ssb-git-new-issue))

;;; One issue or pull request

;;;###autoload
(defun ssb-git-issue (id)
  "Show issue or pull request ID, its changes and its comments."
  (interactive "sIssue (%…): ")
  (ssb-git--call 'issue (list (ssb-git--bin (string-trim id)))
                 (lambda (reply) (ssb-git--show-issue (ssb-git--ok reply)))))

(defun ssb-git--show-issue (i)
  (ssb-git--with-buffer (format "*ssb-git %s*" (ssb--short-id (ssb-git--get i 'id)))
      #'ssb-git-issue-mode
    (setq ssb-git--issue i)
    (let ((pr (eq (ssb-git--get i 'kind) 'pull_request))
          (start (point)))
      (insert (propertize (ssb-git--title i) 'face 'bold) "\n")
      (insert (propertize (format "%s %s" (ssb-git--state-label i)
                                  (if pr "pull request" "issue"))
                          'face (if (ssb-git--true (ssb-git--get i 'open)) 'success 'shadow))
              (format ", %s\n" (ssb-git--date (ssb-git--get i 'ts))))
      (ssb-git--insert-author i "by ")
      (insert "on " (ssb-git--url (ssb-git--get i 'repo)) "\n")
      (when pr
        (insert (format "wants %s:%s merged into %s\n"
                        (ssb--short-id (ssb-git--get i 'head_repo))
                        (or (ssb-git--str (ssb-git--get i 'head_branch)) "?")
                        (or (ssb-git--str (ssb-git--get i 'branch)) "?"))))
      (add-text-properties start (point) (list 'ssb-key (ssb-git--get i 'id)))
      (insert "\n" (or (ssb-git--str (ssb-git--get i 'text)) "") "\n")
      (let ((edits (ssb-git--get i 'edits)))
        (when edits
          (insert "\n" (propertize "Changes" 'face 'bold) "\n")
          (dolist (e edits)
            (let ((s (point))
                  (open (ssb-git--get e 'open))
                  (title (ssb-git--str (ssb-git--get e 'title))))
              (insert (format "  %s  %-18s %s%s\n"
                              (ssb-git--date (ssb-git--get e 'ts))
                              (truncate-string-to-width (ssb-git--who e) 18)
                              (string-join (delq nil (list (cond ((eq open 'true) "reopened")
                                                                 ((eq open 'false) "closed"))
                                                           (and title (format "retitled %S" title))))
                                           ", ")
                              (if (ssb-git--true (ssb-git--get e 'counted)) ""
                                (propertize "   (not counted: neither the author nor the repo's owner)"
                                            'face 'shadow))))
              (add-text-properties s (point) (list 'ssb-key (ssb-git--get e 'msg)
                                                   'ssb-author (ssb-git--get e 'author)))))))
      (let ((comments (ssb-git--get i 'comments)))
        (insert "\n" (propertize (pcase (length comments)
                                    (0 "No comments")
                                    (1 "1 comment")
                                    (n (format "%d comments" n)))
                                  'face 'bold)
                "\n")
        (dolist (c comments)
          (let ((s (point))
                (indent (make-string (* 2 (max 0 (1- (or (ssb-git--get c 'depth) 1)))) ?\s)))
            (insert "\n" indent
                    (propertize (format "%s, %s" (ssb-git--who c) (ssb-git--date (ssb-git--get c 'ts)))
                                'face 'font-lock-keyword-face)
                    "\n")
            (dolist (line (split-string (or (ssb-git--str (ssb-git--get c 'text)) "") "\n"))
              (insert indent line "\n"))
            (add-text-properties s (point) (list 'ssb-key (ssb-git--get c 'key)
                                                 'ssb-author (ssb-git--get c 'author)))))))
    (goto-char (point-min))))

(define-derived-mode ssb-git-issue-mode special-mode "SSB-Git-Issue"
  "An issue or pull request on SSB.
\\{ssb-git-issue-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _) (ssb-git-issue (ssb-git--get ssb-git--issue 'id)))))

(defun ssb-git--issue-id ()
  (or (ssb-git--get ssb-git--issue 'id) (user-error "Not in an issue buffer")))

(defun ssb-git-toggle-open ()
  "Close this issue or pull request if open, reopen it if closed."
  (interactive)
  (let* ((id (ssb-git--issue-id))
         (open (ssb-git--true (ssb-git--get ssb-git--issue 'open))))
    (when (y-or-n-p (format "%s %s? " (if open "Close" "Reopen") (ssb-git--title ssb-git--issue)))
      (ssb-git--call 'set_open (list (ssb-git--bin id) (if open 'false 'true))
                     (lambda (reply)
                       (ssb-git--ok reply)
                       (message "%s" (if open "Closed" "Reopened"))
                       (ssb-git-issue id))))))

(defun ssb-git-comment ()
  "Comment on this issue or pull request."
  (interactive)
  (let ((id (ssb-git--issue-id)))
    (ssb-git--compose
     (format "Comment on %s" (ssb-git--title ssb-git--issue)) nil
     (lambda (_title text)
       (ssb-git--call 'comment (list (ssb-git--bin id) (ssb-git--bin text))
                      (lambda (reply)
                        (ssb-git--ok reply)
                        (message "Commented")
                        (ssb-git-issue id)))))))

(defun ssb-git-checkout-pull-request (dir)
  "Fetch this pull request's branch into the clone in DIR and check it out."
  (interactive
   (list (let ((top (locate-dominating-file default-directory ".git")))
           (read-directory-name "Clone to check it out in: " top nil t))))
  (let* ((i ssb-git--issue)
         (head (or (ssb-git--get i 'head_repo) (user-error "Not a pull request")))
         (hb (ssb-git--str (ssb-git--get i 'head_branch)))
         (branch (concat "pr/" (ssb-git--safe-name
                                (substring (string-remove-prefix "%" (ssb-git--get i 'id)) 0 8)))))
    (ssb-git--run-git (list "fetch" (ssb-git--url head) (format "%s:%s" hb branch))
                      (expand-file-name dir)
                      (format "Fetched %s as %s" hb branch)
                      (lambda ()
                        (ssb-git--run-git (list "checkout" branch) (expand-file-name dir)
                                          (format "On %s in %s" branch dir))))))

(let ((map ssb-git-issue-mode-map))
  (define-key map (kbd "r") #'ssb-git-comment)
  (define-key map (kbd "x") #'ssb-git-toggle-open)
  (define-key map (kbd "o") #'ssb-git-checkout-pull-request)
  (define-key map (kbd "t") #'ssb-git-thread)
  (define-key map (kbd "f") #'ssb-browse-author-feed)
  (define-key map (kbd "n") #'ssb-git-next-item)
  (define-key map (kbd "p") #'ssb-git-prev-item))

(defun ssb-git-thread ()
  "Open this issue's comment thread in maxbutt's thread view."
  (interactive)
  (let ((id (ssb-git--issue-id)))
    (erl-rpc #'ssb--display-thread (list id) ssb-node 'maxbutt 'thread
             (list (ssb-git--bin id)))))

;;; New issues and pull requests

(defun ssb-git-new-issue ()
  "File a new issue against this repo."
  (interactive)
  (let ((repo (ssb-git--repo-id)))
    (ssb-git--compose
     (format "New issue on %s" (ssb--short-id repo)) t
     (lambda (title text)
       (ssb-git--call 'new_issue (list (ssb-git--bin repo) (ssb-git--bin title) (ssb-git--bin text))
                      (lambda (reply)
                        (ssb-git-issue (ssb-git--ok reply))))))))

(defun ssb-git-new-pull-request (head-repo head-branch branch)
  "Ask for HEAD-REPO's HEAD-BRANCH to be merged into this repo's BRANCH.
Push the branch first: a pull request names a branch the repos' readers
can already fetch."
  (interactive
   (let* ((r ssb-git--repo)
          (head (string-remove-prefix "refs/heads/" (or (ssb-git--str (ssb-git--get r 'head)) "master"))))
     (list (string-remove-prefix
            "ssb://" (read-string "Repo with your branch (ssb://%…): "
                                  (ssb-git--url (ssb-git--repo-id))))
           (read-string "Your branch: ")
           (read-string "Merge into: " head))))
  (let ((repo (ssb-git--repo-id)))
    (ssb-git--compose
     (format "Pull request: %s into %s" head-branch branch) t
     (lambda (title text)
       (ssb-git--call 'new_pull_request
                      (list (ssb-git--bin repo) (ssb-git--bin branch) (ssb-git--bin head-repo)
                            (ssb-git--bin head-branch) (ssb-git--bin title) (ssb-git--bin text))
                      (lambda (reply)
                        (ssb-git-issue (ssb-git--ok reply))))))))

;;; Compose

(defvar-local ssb-git--compose-send nil
  "Function of (TITLE TEXT) that publishes this buffer.")
(defvar-local ssb-git--compose-titled nil
  "Whether the first line is a title.")
(defvar-local ssb-git--compose-start nil
  "Where the editable text starts.")

(define-minor-mode ssb-git-compose-mode
  "Composing an issue, pull request or comment.
\\{ssb-git-compose-mode-map}"
  :lighter " SSB-Git-Compose"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'ssb-git-compose-send)
            (define-key map (kbd "C-c C-k") #'ssb-git-compose-cancel)
            map))

(defun ssb-git--compose (header titled send)
  "Open a compose buffer under HEADER; SEND gets (TITLE TEXT).
With TITLED, the first line is the title and the rest the text."
  (let ((buf (get-buffer-create "*ssb-git compose*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (fboundp 'markdown-mode) (markdown-mode) (text-mode))
        (ssb-git-compose-mode 1)
        (setq ssb-git--compose-send send
              ssb-git--compose-titled titled)
        (insert header "  (C-c C-c to send, C-c C-k to cancel)\n"
                (if titled "First line: the title.  Then a blank line and the text.\n" "")
                (make-string 72 ?-) "\n")
        (add-text-properties (point-min) (1- (point))
                             '(read-only t front-sticky (read-only)
                               rear-nonsticky (read-only) face shadow))
        (setq ssb-git--compose-start (point-marker))
        (setq buffer-read-only nil)))
    (pop-to-buffer buf)))

(defun ssb-git-compose-send ()
  "Publish this compose buffer."
  (interactive)
  (let* ((body (string-trim (buffer-substring-no-properties ssb-git--compose-start (point-max))))
         (lines (split-string body "\n"))
         (title (and ssb-git--compose-titled (string-trim (car lines))))
         (text (if ssb-git--compose-titled
                   (string-trim (string-join (cdr lines) "\n"))
                 body)))
    (when (string= body "") (user-error "Nothing to send"))
    (when (and ssb-git--compose-titled (string= title "")) (user-error "The first line is the title"))
    (funcall ssb-git--compose-send title text)
    (kill-buffer (current-buffer))))

(defun ssb-git-compose-cancel ()
  "Discard this compose buffer."
  (interactive)
  (when (y-or-n-p "Discard? ")
    (kill-buffer (current-buffer))))

(provide 'ssb-git)
;;; ssb-git.el ends here
