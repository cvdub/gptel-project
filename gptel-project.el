;;; gptel-project.el --- Project based context for gptel  -*- lexical-binding: t; -*-


;; Copyright (C) 2025  Christian Vanderwall

;; Author: Christian Vanderwall <christian@cvdub.net>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
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

;; This package is an attempt to replicate Open AI's project based
;; chats in Emacs, using gptel and project.el

;;; Code:

(require 'gptel)
(require 'project)
(require 'f)

(defgroup gptel-project nil
  "Project-based context, transcripts, and summaries for gptel."
  :group 'tools
  :prefix "gptel-project-")

(defcustom gptel-project-chat-transcripts-directory ".gptel-chats/"
  "Directory where project chat transcripts are saved."
  :type 'directory :group 'gptel-project)

(defcustom gptel-project-autosave-chat-transcripts t
  "Automatically save chat transcripts after each LLM response."
  :type 'boolean :group 'gptel-project)

(defcustom gptel-project-automatically-update-summary t
  "Automatically update project summary after each LLM response."
  :type 'boolean :group 'gptel-project)

(defcustom gptel-project-chat-transcript-filename-generator-model 'gpt-5-nano
  "Model used for generating chat transcript filenames."
  :type 'symbol :group 'gptel-project)

(defcustom gptel-project-summary-generator-model 'gpt-5-mini
  "Model used for generating project summaries from chat transcripts."
  :type 'symbol :group 'gptel-project)

(defcustom gptel-project-summary-filename "summary.txt"
  "Filename for project summary."
  :type 'string :group 'gptel-project)

(defcustom gptel-project-description-filename "project-description.txt"
  "Filename for project description."
  :type 'string :group 'gptel-project)

(defcustom gptel-project-summary-prompt
  "You are summarizing a chat transcript for future reference about an \
ongoing project. If an existing summary is provided, update that summary \
instead of creating a new one.

Your goal is to produce a concise but detailed project memory that another \
AI could use as context for future conversations on the same project.

Instructions:
1. Focus on facts, decisions, constraints, goals, and unresolved issues that\
 are likely to remain relevant over time.
2. Exclude irrelevant or time-sensitive chatter (e.g., greetings, temporary \
scheduling).
3. Preserve technical details, terminology, and examples from the conversation.
4. Use clear, structured sections so the summary is easy to scan later.
5. Avoid guessing at missing information—only include what’s stated in the \
transcript.
6. Where useful, consolidate related points into bullet lists.

Output format:
- Goals / Objectives:
- Key Decisions & Agreements:
- Technical Details:
- Constraints & Requirements:
- Unresolved Questions / Next Steps:

Write in a neutral, factual tone. Keep it concise but thorough enough to fully \
brief someone joining the project."
  "System prompt for creating/updating project summaries."
  :type 'string :group 'gptel-project)

(defcustom gptel-project-directive-prompt
  "You are a large language model living in Emacs and a helpful \
assistant. Respond concisely.

Instructions:
1. Always check the summary before answering, and ensure your responses \
are consistent with it.
2. If new information in this conversation contradicts the summary, note \
the change explicitly and be ready to update the summary later.
3. Use the summary to fill in relevant details without asking the user to \
repeat themselves.
4. Maintain the same terminology and technical conventions established in \
the summary.
5. Avoid re-stating the entire summary in your responses unless explicitly \
asked.
6. If the user asks a question outside the scope of the summary, answer \
normally, but do not introduce speculative changes to the project record \
unless confirmed.

Your goal is to provide accurate, context-aware, and consistent answers \
that reflect the ongoing state of the project.

Below is the current project summary containing persistent goals, \
constraints, decisions, and unresolved issues. This is your authoritative \
reference for the project. Use it to inform all answers and to maintain \
continuity across sessions.

Project Summary:

%s

Project Description:

%s"
  "System prompt template for project based chats."
  :type 'string :group 'gptel-project)

(defcustom gptel-project-transcript-filename-prompt
  "Summarize the contents of this chat in a single very short sentence (5 \
words maximum) that can be used as a file name. Return ONLY the file name, \
no explanation or summary. It is OK for the file name to have spaces. Only \
capitalize the first word and proper nouns."
  "System prompt for creating filenames from chat transcripts."
  :type 'string :group 'gptel-project)

(defun gptel-project--project-chats-directory-path ()
  "Return the project directory for saved chat transcripts."
  (expand-file-name gptel-project-chat-transcripts-directory
                    (project-root (project-current))))

(defun gptel-project--summary-file-path ()
  "Return the absolute path to the current project's summary file."
  (expand-file-name gptel-project-summary-filename
                    (gptel-project--project-chats-directory-path)))

(defun gptel-project--description-file-path ()
  "Return the absolute path to the current project's description file."
  (expand-file-name gptel-project-description-filename
                    (gptel-project--project-chats-directory-path)))

(defun gptel-project--transcript-full-filename (filename)
  "Return the absolute path for saving project chat with FILENAME."
  (let ((extension (if (eq major-mode 'org-mode) ".org" ".md")))
    (expand-file-name (concat filename extension) (gptel-project--project-chats-directory-path))))

(defun gptel-project--project-summary-as-string ()
  "Return contents of current project summary file as a string."
  (let ((summary-file (gptel-project--summary-file-path)))
    (if (file-exists-p summary-file)
        (f-read-text summary-file)
      "None")))

(defun gptel-project--project-description-as-string ()
  "Return contents of current project description file as a string."
  (let ((description-file (gptel-project--description-file-path)))
    (if (file-exists-p description-file)
        (f-read-text description-file)
      "None")))

(defun gptel-project--buffer-to-context (&optional buffer)
  "Return contents of BUFFER as a string suitable for use as LLM context.

Uses current buffer if BUFFER is nil. Assumes buffer is an org or markdown file."
  (with-current-buffer (or buffer (current-buffer))
    (concat "```" (if (eq major-mode 'org-mode) "org" "markdown") "\n"
            (buffer-substring-no-properties (point-min) (point-max))
            "\n```")))

(defun gptel-project-directive ()
  "Directive for project based chats."
  (format gptel-project-directive-prompt
          (gptel-project--project-summary-as-string)
          (gptel-project--project-description-as-string)))

(defun gptel-project--ensure-chats-dir ()
  "Ensure chat directory exists."
  (let ((dir (gptel-project--project-chats-directory-path)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun gptel-project-update-summary ()
  "Update the project summary with the current chat transcript."
  (message "Updating gptel project summary for %s" (project-name (project-current)))
  (let ((gptel-model gptel-project-summary-generator-model))
    (gptel-request (format "Existing summary:\n\n%s\n\nChat transcript:\n\n%s"
                           (gptel-project--project-summary-as-string)
                           (gptel-project--buffer-to-context))
      :system
      gptel-project-summary-prompt
      :callback
      (lambda (resp info)
        (if (stringp resp)
            (progn
              (gptel-project--ensure-chats-dir)
              (with-temp-file (gptel-project--summary-file-path)
                (insert resp))
              (message "Updated gptel project summary for %s" (project-name (project-current))))
          (message "Error(%s): Failed to update project summary. Did not receive a response from the LLM."
                   (plist-get info :status)))))))

(defun gptel-project--generate-transcript-filename-and-save ()
  "Create a chat transcript filename using the transcript as context."
  (let ((gptel-model gptel-project-chat-transcript-filename-generator-model))
    (gptel-request (gptel-project--buffer-to-context)
      :system
      gptel-project-transcript-filename-prompt
      :callback
      (lambda (resp info)
        (if (stringp resp)
            (let ((buf (plist-get info :buffer)))
              (with-current-buffer buf
                (gptel-project--ensure-chats-dir)
                (rename-visited-file (gptel-project--transcript-full-filename resp))
                (when gptel-project-autosave-chat-transcripts
                  (save-buffer))
                (when gptel-project-automatically-update-summary
                  (gptel-project-update-summary))))
          (message "Error(%s): Failed to name chat transcript. Did not receive a response from the LLM."
                   (plist-get info :status)))))))

(defun gptel-project--save-chat-transcript (_ _)
  "Generate a chat transcript filename if none exists, then save."
  (if buffer-file-name
      (when gptel-project-autosave-chat-transcripts
        (save-buffer))
    (gptel-project--generate-transcript-filename-and-save)))

(defun gptel-project-chat (name &optional _ initial interactivep)
  "Switch to or start a project chat session with NAME.

Ask for API-KEY if `gptel-api-key' is unset.

If region is active, use it as the INITIAL prompt.  Returns the
buffer created or switched to.

INTERACTIVEP is t when gptel is called interactively.

Only suggests existing buffers visiting files under the project chats directory."
  (interactive
   (let* ((backend (default-value 'gptel-backend))
          (backend-name
           (format "*%s: %s*" (project-name (project-current)) (gptel-backend-name backend)))
          (chats-dir (file-name-as-directory (gptel-project--project-chats-directory-path))))
     (list (read-buffer
            "Create or choose gptel buffer: "
            backend-name nil
            (lambda (b)
              (and-let* ((buf  (get-buffer (or (car-safe b) b)))
                         ((buffer-local-value 'gptel-mode buf))
                         (file (buffer-local-value 'buffer-file-name buf)))
                (file-in-directory-p file chats-dir))))
           (condition-case nil
               (gptel--get-api-key (gptel-backend-key backend))
             ((error user-error)
              (setq gptel-api-key
                    (read-passwd (format "%s API key: " backend-name)))))
           (and (use-region-p)
                (buffer-substring (region-beginning)
                                  (region-end)))
           t)))
  (let ((default-directory (gptel-project--project-chats-directory-path)))
    (gptel name nil initial interactivep)))

;;;###autoload
(define-minor-mode gptel-project-mode
  "Global minor to enabled project-based context, transcripts, and summaries for gptel."
  :init-value nil
  :global t
  :lighter " gptel-proj"
  (if gptel-project-mode
      (progn
        (add-to-list 'gptel-directives '(project . gptel-project-directive))
        (setq gptel--system-message #'gptel-project-directive)
        (add-hook 'gptel-post-response-functions
                  #'gptel-project--save-chat-transcript))
    (progn
      (remove-hook 'gptel-post-response-functions
                   #'gptel-project--save-chat-transcript)
      (setq gptel--system-message (alist-get 'default gptel-directives)
            gptel-directives (assq-delete-all 'project gptel-directives)))))

(provide 'gptel-project)

;;; gptel-project.el ends here
