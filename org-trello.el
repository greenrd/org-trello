;;; org-trello.el --- Org minor mode to synchronize with trello

;; Copyright (C) 2013 Antoine R. Dumont <eniotna.t AT gmail.com>

;; Author: Antoine R. Dumont <eniotna.t AT gmail.com>
;; Maintainer: Antoine R. Dumont <eniotna.t AT gmail.com>
;; Version: 0.1.6
;; Package-Requires: ((org "8.0.7") (dash "1.5.0") (request "0.2.0") (cl-lib "0.3.0") (json "1.2") (elnode "0.9.9.7.6") (esxml "0.3.0") (s "1.7.0"))
;; Keywords: org-mode trello sync org-trello
;; URL: https://github.com/ardumont/org-trello

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING. If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Minor mode for org-mode to sync org-mode and trello
;;
;; 1) Add the following to your emacs init file
;; (require 'org-trello)
;; (add-hook 'org-mode-hook 'org-trello-mode)
;;
;; 2) Once - Install the consumer-key and the read-write token for org-trello to be able to work in your name with your trello boards (C-c o i)
;; M-x org-trello/install-key-and-token
;;
;; 3) Once per org-mode file/board you want to connect to (C-c o I)
;; M-x org-trello/install-board-and-lists-ids
;;
;; 4) You can also create a board directly from a org-mode buffer (C-c o b)
;; M-x org-trello/create-board
;;
;; 5) Check your setup (C-c o d)
;; M-x org-trello/check-setup
;;
;; 6) Help (C-c o h)
;; M-x org-trello/help-describing-setup

;;; Code:


(require 'org)
(require 'json)
(require 'dash)
(require 'request)
(eval-when-compile (require 'cl-lib))
(require 'parse-time)
(require 'elnode)
(require 'timer)
(require 's)



;; #################### overriding setup



;; #################### static setup

(defvar *ORGTRELLO-VERSION*           "0.1.6"            "Version")
(defvar *consumer-key*                nil                "Id representing the user.")
(defvar *access-token*                nil                "Read/write access token to use trello on behalf of the user.")
(defvar *ORGTRELLO-MARKER*            "orgtrello-marker" "A marker used inside the org buffer to synchronize entries.")
(defvar *do-sync-query*               t                  "An alias to t to make the boolean more significant in the given context.")
(defvar *do-save-buffer*              t                  "Another alias to t to make the boolean more significant in the given context.")
(defvar *do-reload-setup*             t                  "Another alias to t to make the boolean more significant in the given context.")
(defvar *do-not-display-log*          t                  "Another alias to t to make the boolean more significant in the given context.")
(defvar *ORGTRELLO-LEVELS*            '(1 2 3)           "Current levels 1 is card, 2 is checklist, 3 is item.")
(defvar *ORGTRELLO-ACTION-SYNC*       "sync-entity"      "Possible action regarding the entity synchronization.")
(defvar *ORGTRELLO-ACTION-DELETE*     "delete"           "Possible action regarding the entity deletion.")

(defvar *ORGTRELLO-NATURAL-ORG-CHECKLIST* t
  "Permit the user to choose the natural org checklists over the first org-trello one (present from the start which are more basic).
   To alter this behavior, update in your init.el:
   (require 'org-trello)
   (org-trello/activate-natural-org-checkboxes)")

(defvar *ORGTRELLO-CHECKLIST-UPDATE-ITEMS* nil
  "OBSOLETE: A variable to permit the checklist's status to be pass along to its items. t, if checklist's status is DONE, the items are updated to DONE (org-mode buffer and trello board), nil only the items's status is used.
   To let the user completely choose what status he/she wants for every level, just change in your init.el file:
   (require 'org-trello)
   (setq *ORGTRELLO-CHECKLIST-UPDATE-ITEMS* nil)

If you want to use this, we recommand to use the native org checklists - http://orgmode.org/manual/Checkboxes.html.")



;; #################### orgtrello-version

(defun org-trello/version () (interactive) "Version of org-trello"
  (message "org-trello version: %s" *ORGTRELLO-VERSION*))



;; #################### orgtrello-log

(defvar *OT/NOLOG* 0)
(defvar *OT/ERROR* 1)
(defvar *OT/WARN*  2)
(defvar *OT/INFO*  3)
(defvar *OT/DEBUG* 4)
(defvar *OT/TRACE* 5)

(defvar *orgtrello-log/level* *OT/INFO*
  "Set log level.
Levels:
0 - no logging   (*OT/NOLOG*)
1 - log errors   (*OT/ERROR*)
2 - log warnings (*OT/WARN*)
3 - log info     (*OT/INFO*)
4 - log debug    (*OT/DEBUG*)
5 - log trace    (*OT/TRACE*)
To change such level, add this to your init.el file: (setq *orgtrello-log/level* *OT/TRACE*)")

(defun orgtrello-log/msg (level &rest args)
  "Log message."
  (when (<= level *orgtrello-log/level*)
    (apply 'message args)))

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello-log loaded!")



;; #################### orgtrello-hash

(defun orgtrello-hash/make-hash-org (level keyword name id due position buffer-name)
  "Utility function to ease the creation of the orgtrello-metadata"
  (let ((h (make-hash-table :test 'equal)))
    (puthash :buffername buffer-name h)
    (puthash :position   position    h)
    (puthash :level      level       h)
    (puthash :keyword    keyword     h)
    (puthash :name       name        h)
    (puthash :id         id          h)
    (puthash :due        due         h)
    h))

(defun orgtrello-hash/make-hash (method uri &optional params)
  "Utility function to ease the creation of the map - wait, where are my clojure data again!?"
  (let ((h (make-hash-table :test 'equal)))
    (puthash :method method h)
    (puthash :uri    uri    h)
    (if params (puthash :params params h))
    h))

(defun orgtrello-hash/make-properties (properties)
  "Given a list of key value pair, return a hash table."
  (cl-reduce
   (lambda (map list-key-value)
     (let ((key   (car list-key-value))
           (value (cdr list-key-value)))
       (puthash key value map)
       map))
   properties
   :initial-value (make-hash-table :test 'equal)))

(defun orgtrello-hash/key (s)
  "Given a string, compute its key format."
  (format ":%s:" s))

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello-hash loaded!")



;; #################### orgtrello-cbx

(defun orgtrello-cbx/checkbox-p ()
  "Is there a checkbox at point?"
  (and *ORGTRELLO-NATURAL-ORG-CHECKLIST* (org-at-item-checkbox-p)))

(defun orgtrello-cbx/--to-properties (alist)
  "Serialize an association list to json."
  (json-encode-hash-table (orgtrello-hash/make-properties alist)))

(defun orgtrello-cbx/--from-properties (string)
  "Deserialize from json to list."
  (if string
      (json-read-from-string string)))

(defun orgtrello-cbx/--checkbox-split (s)
  "Split the checkbox into the checkbox data and the checkbox metadata."
  (s-split ":PROPERTIES:" s))

(defun orgtrello-cbx/--checkbox-metadata (s)
  "Retrieve the checkbox's metadata."
  (-when-let (res (-> s
                      orgtrello-cbx/--checkbox-split
                      second))
             (s-trim-left res)))

(defun orgtrello-cbx/--checkbox-data (s)
  "Retrieve the checkbox's data."
    (-> s
      orgtrello-cbx/--checkbox-split
      first
      s-trim-right))

(defun orgtrello-cbx/--read-properties (s)
  "Read the properties from the current string."
  (->> s
       orgtrello-cbx/--checkbox-metadata
       orgtrello-cbx/--from-properties))

(defun orgtrello-cbx/--read-checkbox! ()
  "Read the full checkbox's content"
  (buffer-substring-no-properties (point-at-bol) (point-at-eol)))

(defun orgtrello-cbx/--read-properties-from-point (pt)
  "Read the properties from the current point."
  (save-excursion
    (goto-char pt)
    (orgtrello-cbx/--read-properties (orgtrello-cbx/--read-checkbox!))))

;; (expectations
;;   (expect '((orgtrello-id . "123")) (with-temp-buffer
;;                                       (insert "- [X] some checkbox :PROPERTIES: {\"orgtrello-id\":\"123\"}")
;;                                       (forward-line -1)
;;                                       (orgtrello-cbx/--read-properties-from-point))))


(defun orgtrello-cbx/--update-properties (checkbox-string properties)
  "Given the current checkbox-string and the new properties, update the properties in the current entry."
  (s-join " :PROPERTIES: "  `(,(orgtrello-cbx/--checkbox-data checkbox-string)
                              ,(orgtrello-cbx/--to-properties properties))))

(defun orgtrello-cbx/--justify-property-current-line (full-line length)
  "Justify the properties to the left so that the line makes a length of length. For this insert whites before the :PROPERTIES: before."
  (let ((nb-of-spaces (->> full-line length (- length) 1-)))
    (if (< 0 nb-of-spaces)
        (let ((current-properties-str    (format ":PROPERTIES: %s" (orgtrello-cbx/--checkbox-metadata full-line)))
              (current-data-str          (orgtrello-cbx/--checkbox-data full-line)))
          (format "%s%s%s" current-data-str (orgtrello/--space nb-of-spaces) current-properties-str))
        full-line)))

(defun orgtrello-cbx/--update-properties-and-justify (checkbox-string properties)
  "Given the current checkbox-string and the new properties, update the properties in the current entry and justify."
  (-> (orgtrello-cbx/--update-properties checkbox-string properties)
      (orgtrello-cbx/--justify-property-current-line (current-fill-column))))

(defun orgtrello-cbx/--write-properties-at-point (pt properties)
  "Given the new properties, update the current entry."
  (save-excursion
    (goto-char pt)
    (let* ((current-checkbox-str (orgtrello-cbx/--read-checkbox!))
           (updated-checkbox-str (orgtrello-cbx/--update-properties-and-justify current-checkbox-str properties)))
      (beginning-of-line)
      (kill-line)
      (insert updated-checkbox-str))))

(defun orgtrello-cbx/--key-to-search (key)
  "Search the key key as a symbol"
  (if (stringp key) (intern key) key))

(defun orgtrello-cbx/--org-get-property (key properties)
  "Internal accessor to the key property."
  (-> key
      orgtrello-cbx/--key-to-search
      (assoc-default properties)))

(defun orgtrello-cbx/--org-update-property (key value properties)
  "Internal accessor to the key property."
  (->> properties
       (orgtrello-cbx/--org-delete-property key)
       (cons `(,(orgtrello-cbx/--key-to-search key) . ,value))))

(defun orgtrello-cbx/--org-delete-property (key properties)
  "Delete the key from the properties."
  (-> key
      orgtrello-cbx/--key-to-search
      (assq-delete-all properties)))

(defun orgtrello-cbx/org-set-property (key value)
  "Read the properties. Add the new property key with the value value. Write the new properties."
  (let ((current-point (point)))
    (->> current-point
         orgtrello-cbx/--read-properties-from-point
         (orgtrello-cbx/--org-update-property key value)
         (orgtrello-cbx/--write-properties-at-point current-point))))

(defun orgtrello-cbx/org-get-property (point key)
  "Retrieve the value for the key key."
  (->> point
       orgtrello-cbx/--read-properties-from-point
       (orgtrello-cbx/--org-get-property key)))

(defun orgtrello-cbx/org-delete-property (key)
  "Delete the property key from the properties."
  (let ((current-point (point)))
    (->> current-point
         orgtrello-cbx/--read-properties-from-point
         (orgtrello-cbx/--org-delete-property key)
         (orgtrello-cbx/--write-properties-at-point current-point))))

;; (with-temp-buffer
;;   (insert "- [X] call people [4/4]")
;;   (goto-char (point-min))
;;   (orgtrello-cbx/org-set-property "temporary-key" "temporary-value"))

(defun orgtrello-cbx/--org-split-data (s)
  "Split the string into meta data with -."
  (->> s
       (s-replace "[ ]" "[]")
       (s-split " ")))

(defun orgtrello-cbx/--list-is-checkbox-p (l)
  "Is this a checkbox?"
  (string= "-" (first (--drop-while (string= "" it) l))))

(defun orgtrello-cbx/--level (l)
  "Given a list of strings, compute the level (starts at 2).
String look like:
- ('- '[X] 'call 'people '[4/4])
- (' '  '- '[X] 'call 'people '[4/4]).
To ease the computation, we consider level 4 if no - to start with, and to avoid missed typing, we consider level 2 if there is no space before the - and level 3 otherwise."
    (if (orgtrello-cbx/--list-is-checkbox-p l)
      (if (string= "-" (car l)) 2 3)
      4))

(defun orgtrello-cbx/--retrieve-status (l)
  (car (--drop-while (not (or (string= "[]" it)
                              (string= "[X]" it)
                              (string= "[-]" it)
                              (string= "[ ]" it))) l)))

(defun orgtrello-cbx/--status (s)
  "Given a checklist status, return the TODO/DONE for org-trello to work."
  (if (string= "[X]" s) "DONE" "TODO"))

(defun orgtrello-cbx/--name (s status)
  "Retrieve the name of the checklist"
  (->> s
       (s-replace "[ ]" "[]")
       s-trim-left
       (s-chop-prefix "-")
       s-trim-left
       (s-chop-prefix status)
       s-trim))

(defun orgtrello-cbx/--metadata-from-checklist (full-checklist)
  "Given a checklist string, extract the list of metadata"
  (let* ((oc/--checklist-data   (orgtrello-cbx/--checkbox-data full-checklist))
         (oc/--meta             (orgtrello-cbx/--org-split-data oc/--checklist-data))
         (oc/--level            (orgtrello-cbx/--level oc/--meta))
         (oc/--status-retrieved (orgtrello-cbx/--retrieve-status oc/--meta))
         (oc/--status           (orgtrello-cbx/--status oc/--status-retrieved))
         (oc/--name             (orgtrello-cbx/--name oc/--checklist-data oc/--status-retrieved)))
      (list oc/--level nil oc/--status nil oc/--name nil)))

(defun orgtrello-cbx/org-checkbox-metadata ()
  "Extract the metadata about the checklist - this is the symmetrical as org-heading-components but for the checklist.
Return the components of the current heading.
This is a list with the following elements:
- the level as an integer                                          - (begins at 2)
- the reduced level                                                - always nil
- the TODO keyword, or nil                                         - [], [-] map to TODO, [X] map to DONE
- the priority character, like ?A, or nil if no priority is given  - nil
- the headline text itself, or the tags string if no headline text - the name of the checkbox
- the tags string, or nil.                                         - nil"
  (save-excursion
    (beginning-of-line)
    (orgtrello-cbx/--metadata-from-checklist (orgtrello-cbx/--read-checkbox!))))

(defun orgtrello-cbx/--get-level (meta)
  "Retreve the level from the meta describing the checklist"
  (car meta))

(defun orgtrello-cbx/--org-up! (destination-level)
  "An internal function to get back to the current entry's parent - return the level found or nil if no other level is found."
  (let ((current-level (orgtrello-cbx/--get-level (orgtrello-cbx/org-checkbox-metadata))))
    (cond ((= current-level destination-level) destination-level) ;; nothing to do
          ((= 2 current-level)                 (org-up-heading-safe)) ;; level 2, then the first level is a heading
          (t                                   (progn
                                                 (forward-line -1)
                                                 (orgtrello-cbx/--org-up! destination-level))))))

(defun orgtrello-cbx/org-up! ()
  "A function to get back to the current entry's parent."
  (-> (orgtrello-cbx/org-checkbox-metadata)
      orgtrello-cbx/--get-level
      1-
      orgtrello-cbx/--org-up!))

(defun orgtrello-cbx/--private-next-checklist-point ()
  "Compute the next checkbox's beginning of line. Beware, not for external use. Does not preserve the current position - use  orgtrello-cbx/--next-checklist-point.
 If hitting a heading or the end of the file, return nil."
  (if (or (org-at-heading-p) (<= (point-max) (point)))
      nil
      (progn
        (if (orgtrello-cbx/checkbox-p)
            (point)
            (progn
              (forward-line)
              (orgtrello-cbx/--private-next-checklist-point))))))

(defun orgtrello-cbx/--next-checklist-point ()
  "Compute the next checkbox's beginning of line. Does preserve the current position. If hitting a heading or the end of the file, return nil."
  (save-excursion
    (forward-line)
    (orgtrello-cbx/--private-next-checklist-point)))

(defun orgtrello/--map-checkboxes (point-max fn-to-execute)
  "Map over the checkboxes and execute fn when in checkbox. Does not preserve the cursor position."
  (let ((next-checklist (orgtrello-cbx/--next-checklist-point)))
    (when next-checklist
          (goto-char next-checklist)
          (funcall fn-to-execute)
          (orgtrello/--map-checkboxes point-max fn-to-execute))))

(defun orgtrello/--compute-next-sibling-point ()
  "Compute the next sibling point (need to called from a card level)."
  (let* ((current-point      (point))
         (next-heading-point (save-excursion (org-goto-sibling) (point))))
    (if (= current-point next-heading-point) (point-max) (1- next-heading-point))))

(defun orgtrello/map-checkboxes (fn-to-execute)
  "Map over the current checkbox and sync them."
  (save-excursion
    ;; then map over the next checkboxes and sync them
    (orgtrello/--map-checkboxes (orgtrello/--compute-next-sibling-point) fn-to-execute)))

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello-cbx loaded!")



;; #################### orgtrello-data

(defvar *ORGTRELLO-ID* "orgtrello-id" "Key entry used for the trello identifier and the trello marker (the first sync).")

(defun orgtrello-data/--convert-orgmode-date-to-trello-date (orgmode-date)
  "Convert the org-mode deadline into a time adapted for trello."
  (if (and orgmode-date (not (string-match-p "T*Z" orgmode-date)))
      (cl-destructuring-bind (sec min hour day mon year dow dst tz)
                             (--map (if it
                                        (if (< it 10)
                                            (concat "0" (int-to-string it))
                                          (int-to-string it)))
                                    (parse-time-string orgmode-date))
                             (let* ((year-mon-day (concat year "-" mon "-" day "T"))
                                    (hour-min-sec (if hour (concat hour ":" min ":" sec) "00:00:00")))
                               (concat year-mon-day hour-min-sec ".000Z")))
      orgmode-date))

(defun orgtrello-data/org-entity-metadata ()
  "Compute the metadata the org-mode way."
  (org-heading-components))

(defun orgtrello-data/--extract-metadata ()
  "Extract the current metadata depending on the org-trello's checklist policy."
  (if (orgtrello-cbx/checkbox-p)
      ;; checklist
      (orgtrello-cbx/org-checkbox-metadata)
      ;; as before, return the heading meta
      (orgtrello-data/org-entity-metadata)))

(defun orgtrello-data/extract-identifier (point)
  "Extract the identifier from the point."
  (orgtrello-action/org-entry-get point *ORGTRELLO-ID*))

 (defun orgtrello-action/set-property (key value)
  "Either set the propery normally (as for entities) or specifically for checklist."
  (funcall (if (orgtrello-cbx/checkbox-p) 'orgtrello-cbx/org-set-property 'org-set-property) key value))

(defun orgtrello-action/org-entry-get (point key)
  "Extract the identifier from the point."
  (funcall (if (orgtrello-cbx/checkbox-p) 'orgtrello-cbx/org-get-property 'org-entry-get) point key))

(defun orgtrello-data/metadata ()
  "Compute the metadata for a given entry from org but not only (now is able to deal with org checkbox).
Also add some metadata identifier/due-data/point/buffer-name."
  (let* ((orgtrello-data/metadata--point       (point))
         (orgtrello-data/metadata--metadata    (orgtrello-data/--extract-metadata))
         (orgtrello-data/metadata--id          (orgtrello-data/extract-identifier orgtrello-data/metadata--point))
         (orgtrello-data/metadata--due         (orgtrello-data/--convert-orgmode-date-to-trello-date
                                                (orgtrello-action/org-entry-get orgtrello-data/metadata--point "DEADLINE")))
         (orgtrello-data/metadata--buffer-name (buffer-name)))
    (->> orgtrello-data/metadata--metadata
         (cons orgtrello-data/metadata--due)
         (cons orgtrello-data/metadata--id)
         (cons orgtrello-data/metadata--point)
         (cons orgtrello-data/metadata--buffer-name)
         orgtrello-data/--get-metadata)))

(defun orgtrello-action/org-up-parent ()
  "A function to get back to the current entry's parent"
  (funcall (if (orgtrello-cbx/checkbox-p) 'orgtrello-cbx/org-up! 'org-up-heading-safe)))

(defun orgtrello-data/--parent-metadata ()
  "Extract the metadata from the current heading's parent."
  (save-excursion
    (orgtrello-action/org-up-parent)
    (orgtrello-data/metadata)))

(defun orgtrello-data/--grandparent-metadata ()
  "Extract the metadata from the current heading's grandparent."
  (save-excursion
    (orgtrello-action/org-up-parent)
    (orgtrello-action/org-up-parent)
    (orgtrello-data/metadata)))

(defun orgtrello-data/entry-get-full-metadata ()
  "Compute the metadata needed for one entry into a map with keys :current, :parent, :grandparent.
   Returns nil if the level is superior to 4."
  (let* ((current (orgtrello-data/metadata))
         (level   (gethash :level current)))
    (if (< level 4)
        (let* ((parent      (orgtrello-data/--parent-metadata))
               (grandparent (orgtrello-data/--grandparent-metadata))
               (mapdata     (make-hash-table :test 'equal)))
          ;; build the metadata with every important pieces
          (puthash :current     current     mapdata)
          (puthash :parent      parent      mapdata)
          (puthash :grandparent grandparent mapdata)
          mapdata))))

(defun orgtrello-data/current (entry-meta)
  "Given an entry-meta, return the current entry"
  (gethash :current entry-meta))

(defun orgtrello-data/parent (entry-meta)
  "Given an entry-meta, return the current entry"
  (gethash :parent entry-meta))

(defun orgtrello-data/grandparent (entry-meta)
  "Given an entry-meta, return the grandparent entry"
  (gethash :grandparent entry-meta))

(defun orgtrello-data/--get-metadata (heading-metadata)
  "Given the heading-metadata returned by the function 'org-heading-components, make it a hashmap with key :level, :keyword, :name. and their respective value"
  (cl-destructuring-bind (buffer-name point id due level _ keyword _ name &rest) heading-metadata
                         (orgtrello-hash/make-hash-org level keyword name id due point buffer-name)))

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello-data loaded!")



;; #################### orgtrello-api

(defun orgtrello-api/add-board (name &optional description)
  "Create a board"
  (let* ((payload (if description
                      `(("name" . ,name)
                        ("desc" . ,description))
                    `(("name" . ,name)))))
    (orgtrello-hash/make-hash "POST" "/boards" payload)))

(defun orgtrello-api/get-boards ()
  "Retrieve the boards of the current user."
  (orgtrello-hash/make-hash "GET" "/members/me/boards"))

(defun orgtrello-api/get-board (id)
  "Retrieve the boards of the current user."
  (orgtrello-hash/make-hash "GET" (format "/boards/%s" id)))

(defun orgtrello-api/get-cards (board-id)
  "cards of a board"
  (orgtrello-hash/make-hash "GET" (format "/boards/%s/cards" board-id)))

(defun orgtrello-api/get-card (card-id)
  "Detail of a card with id card-id."
  (orgtrello-hash/make-hash "GET" (format "/cards/%s" card-id)))

(defun orgtrello-api/delete-card (card-id)
  "Delete a card with id card-id."
  (orgtrello-hash/make-hash "DELETE" (format "/cards/%s" card-id)))

(defun orgtrello-api/get-lists (board-id)
  "Display the lists of the board"
  (orgtrello-hash/make-hash "GET" (format "/boards/%s/lists" board-id)))

(defun orgtrello-api/close-list (list-id)
  "'Close' the list with id list-id."
  (orgtrello-hash/make-hash "PUT" (format "/lists/%s/closed" list-id) '((value . t))))

(defun orgtrello-api/get-list (list-id)
  "Get a list by id"
  (orgtrello-hash/make-hash "GET" (format "/lists/%s" list-id)))

(defun orgtrello-api/add-list (name idBoard)
  "Add a list - the name and the board id are mandatory (so i say!)."
  (orgtrello-hash/make-hash "POST" "/lists/" `(("name" . ,name) ("idBoard" . ,idBoard))))

(defun orgtrello-api/add-card (name idList &optional due)
  "Add a card to a board"
  (let* ((orgtrello-api/add-card--default-params `(("name" . ,name) ("idList" . ,idList)))
         (orgtrello-api/add-card--params (if due (cons `("due" . ,due) orgtrello-api/add-card--default-params) orgtrello-api/add-card--default-params)))
    (orgtrello-hash/make-hash "POST" "/cards/" orgtrello-api/add-card--params)))

(defun orgtrello-api/get-cards-from-list (list-id)
  "List all the cards"
  (orgtrello-hash/make-hash "GET" (format "/lists/%s/cards" list-id)))

(defun orgtrello-api/move-card (card-id idList &optional name due)
  "Move a card to another list"
  (let* ((orgtrello-api/move-card--default-params `(("idList" . ,idList)))
         (orgtrello-api/move-card--params-name (if name (cons `("name" . ,name) orgtrello-api/move-card--default-params) orgtrello-api/move-card--default-params))
         (orgtrello-api/move-card--params-due  (if due (cons `("due" . ,due) orgtrello-api/move-card--params-name) orgtrello-api/move-card--params-name)))
    (orgtrello-hash/make-hash "PUT" (format "/cards/%s" card-id) orgtrello-api/move-card--params-due)))

(defun orgtrello-api/add-checklist (card-id name)
  "Add a checklist to a card"
  (orgtrello-hash/make-hash "POST"
             (format "/cards/%s/checklists" card-id)
             `(("name" . ,name))))

(defun orgtrello-api/update-checklist (checklist-id name)
  "Update the checklist's name"
  (orgtrello-hash/make-hash "PUT"
             (format "/checklists/%s" checklist-id)
             `(("name" . ,name))))

(defun orgtrello-api/get-checklists (card-id)
  "List the checklists of a card"
  (orgtrello-hash/make-hash "GET" (format "/cards/%s/checklists" card-id)))

(defun orgtrello-api/get-checklist (checklist-id)
  "Retrieve all the information from a checklist"
  (orgtrello-hash/make-hash "GET" (format "/checklists/%s" checklist-id)))

(defun orgtrello-api/delete-checklist (checklist-id)
  "Delete a checklist with checklist-id"
  (orgtrello-hash/make-hash "DELETE" (format "/checklists/%s" checklist-id)))

(defun orgtrello-api/add-items (checklist-id name &optional checked)
  "Add todo items (trello items) to a checklist with id 'id'"
  (let* ((payload (if checked
                      `(("name"  . ,name) ("checked" . ,checked))
                    `(("name" . ,name)))))
    (orgtrello-hash/make-hash "POST" (format "/checklists/%s/checkItems" checklist-id) payload)))

(defun orgtrello-api/update-item (card-id checklist-id item-id name &optional state)
  "Update a item"
  (let* ((payload (if state
                      `(("name"  . ,name) ("state" . ,state))
                    `(("name" . ,name)))))
    (orgtrello-hash/make-hash
     "PUT"
     (format "/cards/%s/checklist/%s/checkItem/%s" card-id checklist-id item-id)
     payload)))

(defun orgtrello-api/get-items (checklist-id)
  "List the checklist items."
    (orgtrello-hash/make-hash "GET" (format "/checklists/%s/checkItems/" checklist-id)))

(defun orgtrello-api/delete-item (checklist-id item-id)
  "Delete a item with id item-id"
  (orgtrello-hash/make-hash "DELETE" (format "/checklists/%s/checkItems/%s" checklist-id item-id)))

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello-api loaded!")



;; #################### orgtrello-query

(defvar *TRELLO-URL* "https://api.trello.com/1" "The needed prefix url for trello")

;; macro? defmethod?

(defun orgtrello-query/gethash-data (key query-map) "Retrieve the data from some query-map" (gethash key query-map))
(defun orgtrello-query/--method (query-map) "Retrieve the http method"    (gethash :method query-map))
(defun orgtrello-query/--uri    (query-map) "Retrieve the http uri"       (gethash :uri query-map))
(defun orgtrello-query/--sync   (query-map) "Retrieve the http sync flag" (gethash :sync query-map))
(defun orgtrello-query/--params (query-map) "Retrieve the http params"    (gethash :params query-map))

(defun orgtrello-query/--retrieve-data  (symbol entity-data) "Own generic accessor"                                    (assoc-default symbol entity-data))
(defun orgtrello-query/--marker         (entity-data) "Extract the marker of the entity from the entity-data"          (orgtrello-query/--retrieve-data 'marker entity-data))
(defun orgtrello-query/--buffername     (entity-data) "Extract the buffername of the entity from the entity-data"      (orgtrello-query/--retrieve-data 'buffername entity-data))
(defun orgtrello-query/--position       (entity-data) "Extract the position of the entity from the entity-data"        (orgtrello-query/--retrieve-data 'position entity-data))
(defun orgtrello-query/--id             (entity-data) "Extract the id of the entity from the entity"                   (orgtrello-query/--retrieve-data 'id entity-data))
(defun orgtrello-query/--name           (entity-data) "Extract the name of the entity from the entity"                 (orgtrello-query/--retrieve-data 'name entity-data))
(defun orgtrello-query/--list-id        (entity-data) "Extract the list identitier of the entity from the entity"      (orgtrello-query/--retrieve-data 'idList entity-data))
(defun orgtrello-query/--checklist-ids  (entity-data) "Extract the checklist identifier of the entity from the entity" (orgtrello-query/--retrieve-data 'idChecklists entity-data))
(defun orgtrello-query/--check-items    (entity-data) "Extract the checklist identifier of the entity from the entity" (orgtrello-query/--retrieve-data 'checkItems entity-data))
(defun orgtrello-query/--card-id        (entity-data) "Extract the card identifier of the entity from the entity"      (orgtrello-query/--retrieve-data 'idCard entity-data))
(defun orgtrello-query/--due            (entity-data) "Extract the due date of the entity from the query response"     (orgtrello-query/--retrieve-data 'due entity-data))
(defun orgtrello-query/--state          (entity-data) "Extract the state of the entity"                                (orgtrello-query/--retrieve-data 'state entity-data))
(defun orgtrello-query/--close-property (entity-data) "Extract the closed property of the entity"                      (orgtrello-query/--retrieve-data 'closed entity-data))
(defun orgtrello-query/--callback       (entity-data) "Extract the callback property of the entity"                    (orgtrello-query/--retrieve-data 'callback entity-data))
(defun orgtrello-query/--sync-          (entity-data) "Extract the sync property of the entity"                        (orgtrello-query/--retrieve-data 'sync entity-data))
(defun orgtrello-query/--level          (entity-data) "Extract the callback property of the entity"                    (orgtrello-query/--retrieve-data 'level entity-data))
(defun orgtrello-query/--method-        (entity-data) "Extract the method property of the entity"                      (orgtrello-query/--retrieve-data 'method entity-data))
(defun orgtrello-query/--uri-           (entity-data) "Extract the uri property of the entity"                         (orgtrello-query/--retrieve-data 'uri entity-data))
(defun orgtrello-query/--params-        (entity-data) "Extract the params property of the entity"                      (orgtrello-query/--retrieve-data 'params entity-data))
(defun orgtrello-query/--start          (entity-data) "Extract the start property of the entity"                       (orgtrello-query/--retrieve-data 'start entity-data))
(defun orgtrello-query/--action         (entity-data) "Extract the action property of the entity"                      (orgtrello-query/--retrieve-data 'action entity-data))

(defun orgtrello-query/--compute-url (server uri)
  "Compute the trello url from the given uri."
  (format "%s%s" server uri))

(cl-defun orgtrello-query/--standard-error-callback (&key error-thrown symbol-status response &allow-other-keys)
  "Standard error callback. Simply displays a message in the minibuffer with the error code."
  (orgtrello-log/msg *OT/DEBUG* "client - Problem during the request to the proxy- error-thrown: %s" error-thrown))

(cl-defun orgtrello-query/--standard-success-callback (&key data &allow-other-keys)
  "Standard success callback. Simply displays a \"Success\" message in the minibuffer."
  (orgtrello-log/msg *OT/DEBUG* "client - Proxy received and acknowledged the request%s" (if data (format " - response data: %S." data) ".")))

(defun orgtrello-query/--authentication-params ()
  "Generates the list of http authentication parameters"
  `((key . ,*consumer-key*) (token . ,*access-token*)))

(defun orgtrello-query/--get (server query-map &optional success-callback error-callback authentication-p)
  "GET"
  (let* ((method (orgtrello-query/--method query-map))
         (uri    (orgtrello-query/--uri    query-map))
         (sync   (orgtrello-query/--sync   query-map)))
    (request (orgtrello-query/--compute-url server uri)
             :sync    sync
             :type    method
             :params  (if authentication-p (orgtrello-query/--authentication-params))
             :parser  'json-read
             :success (if success-callback success-callback 'orgtrello-query/--standard-success-callback)
             :error   (if error-callback error-callback 'orgtrello-query/--standard-error-callback))))

(defun orgtrello-query/--post-or-put (server query-map &optional success-callback error-callback authentication-p)
  "POST or PUT"
  (let* ((method  (orgtrello-query/--method query-map))
         (uri     (orgtrello-query/--uri    query-map))
         (payload (orgtrello-query/--params query-map))
         (sync    (orgtrello-query/--sync   query-map)))
    (request (orgtrello-query/--compute-url server uri)
             :sync    sync
             :type    method
             :params  (if authentication-p (orgtrello-query/--authentication-params))
             :headers '(("Content-type" . "application/json"))
             :data    (json-encode payload)
             :parser  'json-read
             :success (if success-callback success-callback 'orgtrello-query/--standard-success-callback)
             :error   (if error-callback error-callback 'orgtrello-query/--standard-error-callback))))

(defun orgtrello-query/--delete (server query-map &optional success-callback error-callback authentication-p)
  "DELETE"
  (let* ((method (orgtrello-query/--method query-map))
         (uri    (orgtrello-query/--uri    query-map))
         (sync   (orgtrello-query/--sync   query-map)))
    (request (orgtrello-query/--compute-url server uri)
             :sync    sync
             :type    method
             :params  (if authentication-p (orgtrello-query/--authentication-params))
             :success (if success-callback success-callback 'orgtrello-query/--standard-success-callback)
             :error   (if error-callback error-callback 'orgtrello-query/--standard-error-callback))))

(defun orgtrello-query/--dispatch-http-query (method)
  (cond ((string= "GET" method)                              'orgtrello-query/--get)
        ((or (string= "POST" method) (string= "PUT" method)) 'orgtrello-query/--post-or-put)
        ((string= "DELETE" method)                           'orgtrello-query/--delete)))

(defun orgtrello-query/--http (server query-map &optional sync success-callback error-callback authentication-p)
  "HTTP query the server with the query-map."
  (let ((fn-dispatch (orgtrello-query/--dispatch-http-query (orgtrello-query/--method query-map))))
    (if sync
        (progn ;; synchronous request
          (puthash :sync t query-map)
          (let ((request-response (funcall fn-dispatch server query-map success-callback error-callback authentication-p)))
            (request-response-data request-response)))
      (funcall fn-dispatch server query-map success-callback error-callback authentication-p))))

(defun orgtrello-query/http-trello (query-map &optional sync success-callback error-callback)
  "Query the trello api."
  ;; request to trello with authentication
  (orgtrello-query/--http *TRELLO-URL* query-map sync success-callback error-callback t))

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello-query loaded!")



;; #################### orgtrello-action

(defun trace (label e)
  "Decorator for some inaccessible code to easily 'message'."
  (message "TRACE: %s: %S" label e)
  e)

(defun -trace (e &optional label)
  "Decorator for some inaccessible code to easily 'message'."
  (progn
    (if label
        (trace label e)
        (message "TRACE: %S" e))
    e))

(defun orgtrello-action/reload-setup ()
  "Reload orgtrello setup."
  (org-set-regexps-and-options))

(defmacro orgtrello-action/safe-wrap (fn &rest clean-up)
  "A macro to deal with intercept uncaught error when executing the fn call and cleaning up using the clean-up body."
  `(unwind-protect
       (let (retval)
         (condition-case ex
             (setq retval (progn ,fn))
           ('error
            (message (format "### org-trello ### Caught exception: [%s]" ex))
            (setq retval (cons 'exception (list ex)))))
         retval)
     ,@clean-up))

(defun org-action/--execute-controls (controls-or-actions-fns &optional entity)
  "Given a series of controls, execute them and return the results."
  (--map (funcall it entity) controls-or-actions-fns))

(defun org-action/--filter-error-messages (control-or-actions)
  "Given a list of control or actions done, filter only the error message. Return nil if no error message."
  (--filter (not (equal :ok it)) control-or-actions))

(defun org-action/--compute-error-message (error-msgs)
  "Given a list of error messages, compute them as a string."
  (apply 'concat (--map (concat "- " it "\n") error-msgs)))

(defun org-action/--controls-or-actions-then-do (control-or-action-fns fn-to-execute &optional nolog-p)
  "Execute the function fn-to-execute if control-or-action-fns is nil or if the result of apply every function to fn-to-execute is ok."
  (if control-or-action-fns
      (let* ((org-trello/--controls-or-actions-done (org-action/--execute-controls control-or-action-fns))
             (org-trello/--error-messages           (org-action/--filter-error-messages org-trello/--controls-or-actions-done)))
        (if org-trello/--error-messages
            (unless nolog-p
                    ;; there are some trouble, we display all the error messages to help the user understand the problem
                    (orgtrello-log/msg *OT/ERROR* "List of errors:\n %s" (org-action/--compute-error-message org-trello/--error-messages)))
          ;; ok execute the function as the controls are ok
          (funcall fn-to-execute)))
      ;; no control, we simply execute the function
      (funcall fn-to-execute)))

(defun org-action/--functional-controls-then-do (control-fns entity fn-to-execute args)
  "Execute the function fn if control-fns is nil or if the result of apply every function to fn-to-execute is ok."
  (if control-fns
      (let* ((org-trello/--controls-done  (org-action/--execute-controls control-fns entity))
             (org-trello/--error-messages (org-action/--filter-error-messages org-trello/--controls-done)))
        (if org-trello/--error-messages
            ;; there are some trouble, we display all the error messages to help the user understand the problem
            (orgtrello-log/msg *OT/ERROR* "List of errors:\n %s" (org-action/--compute-error-message org-trello/--error-messages))
            ;; ok execute the function as the controls are ok
            (funcall fn-to-execute entity args)))
      ;; no control, we simply execute the function
      (funcall fn-to-execute entity args)))

(defun org-action/--msg-controls-or-actions-then-do (msg control-or-action-fns fn-to-execute &optional save-buffer-p reload-setup-p nolog-p)
  "A simple decorator function to display message in mini-buffer before and after the execution of the control"
  (unless nolog-p (orgtrello-log/msg *OT/INFO* (concat msg "...")))
  ;; now execute the controls and the main action
  (orgtrello-action/safe-wrap
   (org-action/--controls-or-actions-then-do control-or-action-fns fn-to-execute nolog-p)
   (progn
     ;; do we have to save the buffer
     (when save-buffer-p  (save-buffer))
     (when reload-setup-p (orgtrello-action/reload-setup))
     (unless nolog-p (orgtrello-log/msg *OT/INFO* (concat msg " - done!"))))))

(defun org-action/--deal-with-consumer-msg-controls-or-actions-then-do
  (msg control-or-action-fns fn-to-execute &optional save-buffer-p reload-setup-p nolog-p)
  "A simple decorator function to display message in mini-buffer before and after the execution of the control"
  ;; stop the timer
  (orgtrello-timer/stop)
  ;; Execute as usual
  (org-action/--msg-controls-or-actions-then-do msg control-or-action-fns fn-to-execute save-buffer-p reload-setup-p nolog-p)
  ;; start the timer
  (orgtrello-timer/start))



;; #################### orgtrello-proxy

(defvar *ORGTRELLO-PROXY-HOST* "localhost" "proxy host")
(defvar *ORGTRELLO-PROXY-PORT* nil         "proxy port")
(defvar *ORGTRELLO-PROXY-URL*  nil         "proxy url")

(defvar *ORGTRELLO-PROXY-DEFAULT-PORT* 9876 "Default proxy port")
(setq *ORGTRELLO-PROXY-PORT* *ORGTRELLO-PROXY-DEFAULT-PORT*)

(defun orgtrello-proxy/http (query-map &optional sync success-callback error-callback)
  "Query the trello api asynchronously."
  (let ((query-map-proxy (orgtrello-hash/make-hash "POST" "/trello/" query-map)))
    (orgtrello-log/msg *OT/TRACE* "Request to proxy wrapped: %S" query-map-proxy)
    (orgtrello-query/--http *ORGTRELLO-PROXY-URL* query-map-proxy sync success-callback error-callback)))

(defun orgtrello-proxy/http-producer (query-map &optional sync)
  "Query the proxy producer"
  (let ((query-map-proxy (orgtrello-hash/make-hash "POST" "/producer/" query-map)))
    (orgtrello-log/msg *OT/TRACE* "Request to proxy wrapped: %S" query-map-proxy)
    (orgtrello-query/--http *ORGTRELLO-PROXY-URL* query-map-proxy sync)))

(defun orgtrello-proxy/http-consumer (start)
  "Query the http-consumer process once to make it trigger a timer"
  (let ((query-map (orgtrello-hash/make-hash "POST" "/timer/" `((start . ,start)))))
    (orgtrello-query/--http *ORGTRELLO-PROXY-URL* query-map t)))

(defun orgtrello-proxy/--dispatch-http-query (method)
  "Dispach query function depending on the http method input parameter."
  (cond ((string= "GET" method)      'orgtrello-proxy/--get)
        ((or (string= "POST" method)
             (string= "PUT" method)) 'orgtrello-proxy/--post-or-put)
        ((string= "DELETE" method)   'orgtrello-proxy/--delete)))

(defun orgtrello-proxy/--extract-trello-query (http-con)
  "Given an httpcon object, extract the params entry which corresponds to the real trello query."
  (let ((params-proxy-json (caar (elnode-http-params http-con))))
    (json-read-from-string params-proxy-json)))

(defun orgtrello-proxy/--compute-trello-query (query-map-wrapped)
  (let ((method  (orgtrello-query/--method- query-map-wrapped))
        (uri     (orgtrello-query/--uri-    query-map-wrapped))
        (payload (orgtrello-query/--params- query-map-wrapped)))
    (orgtrello-hash/make-hash method uri payload)))

(defun orgtrello-proxy/--response (http-con data)
  "A response wrapper"
  (let ((response-data (json-encode data)))
    (orgtrello-log/msg *OT/TRACE* "Proxy - Responding to client with data '%s'." response-data)
    (elnode-http-start http-con 201 '("Content-type" . "application/json"))
    (elnode-http-return http-con response-data)))

(defun orgtrello-proxy/--compute-entity-level-dir (level)
  "Given a level, compute the folder onto which the file will be serialized."
  (format "%s%s/%s/" elnode-webserver-docroot "org-trello" level))

(defun orgtrello-proxy/response-ok (http-con)
  "OK response from the proxy to the client."
  ;; all is good
  (orgtrello-proxy/--response http-con '((status . "ok"))))

(defun orgtrello-proxy/--elnode-proxy (http-con)
  "Deal with request to trello (for creation/sync request, use orgtrello-proxy/--elnode-proxy-producer)."
  (orgtrello-log/msg *OT/TRACE* "Proxy - Request received. Transmitting...")
  (let* ((query-map-wrapped    (orgtrello-proxy/--extract-trello-query http-con))                     ;; wrapped query is mandatory
         (position             (orgtrello-query/--position query-map-wrapped))                        ;; position is mandatory
         (buffer-name          (orgtrello-query/--buffername query-map-wrapped))                      ;; buffer-name is mandatory
         (standard-callback    (orgtrello-query/--callback query-map-wrapped))                        ;; there is the possibility to transmit the callback from the client to the proxy
         (standard-callback-fn (when standard-callback (symbol-function (intern standard-callback)))) ;; the callback is passed as a string, we want it as a function when defined
         (sync                 (orgtrello-query/--sync- query-map-wrapped))                           ;; there is a possibility to enforce the sync between proxy and client
         (query-map            (orgtrello-proxy/--compute-trello-query query-map-wrapped))            ;; extracting the query
         (name                 (orgtrello-query/--name query-map-wrapped)))                       ;; extracting the name of the entity (optional)
    ;; check out the sync behaviour here
    ;; Execute the request to trello (at the moment, synchronous)
    (orgtrello-query/http-trello query-map sync (when standard-callback-fn (funcall standard-callback-fn buffer-name position name)))
    ;; Answer about the update
    (orgtrello-proxy/response-ok http-con)))

(defun orgtrello-proxy/--compute-metadata-filename (root-dir buffer-name position)
  "Compute the metadata entity filename"
  (format "%s%s-%s.el" root-dir buffer-name position))

(defun orgtrello-proxy/--elnode-proxy-producer (http-con)
  "A handler which is an entity informations producer on files under the docroot/level-entities/"
  (orgtrello-log/msg *OT/TRACE* "Proxy-producer - Request received. Generating entity file...")
  (let* ((query-map-wrapped    (orgtrello-proxy/--extract-trello-query http-con)) ;; wrapped query is mandatory
         (position             (orgtrello-query/--position query-map-wrapped))    ;; position is mandatory
         (buffer-name          (orgtrello-query/--buffername query-map-wrapped))  ;; buffer-name is mandatory
         (level                (orgtrello-query/--level query-map-wrapped))
         (root-dir             (orgtrello-proxy/--compute-entity-level-dir level)))
    ;; generate a file with the entity information
    (with-temp-file (orgtrello-proxy/--compute-metadata-filename root-dir buffer-name position)
      (insert (format "%S\n" query-map-wrapped)))
    ;; all is good
    (orgtrello-proxy/response-ok http-con)))

(defun orgtrello-proxy/--read-lines (fPath)
  "Return a list of lines of a file at FPATH."
  (with-temp-buffer
    (insert-file-contents fPath)
    (split-string (buffer-string) "\n" t)))

(defun orgtrello/compute-marker (buffer-name name position)
  "Compute the orgtrello marker which is composed of buffer-name, name and position"
  (->> (list *ORGTRELLO-MARKER* buffer-name name (if (stringp position) position (int-to-string position)))
       (-interpose "-")
       (apply 'concat)
       sha1
       (concat *ORGTRELLO-MARKER* "-")))

(defun orgtrello-proxy/--remove-file (file-to-remove)
  "Remove metadata file."
  (when (file-exists-p file-to-remove)
        (delete-file file-to-remove)))

(defun orgtrello-proxy/--cleanup-and-save-buffer-metadata (file marker)
  "To cleanup metadata after the all actions are done!"
  ;; cleanup file
  (orgtrello-proxy/--remove-file file)
  ;; save modifs
  (save-buffer))

(defmacro orgtrello-proxy/--safe-wrap-or-throw-error (fn)
  "A macro to deal with intercept uncaught error when executing the fn call and cleaning up using the clean-up body. If error is thrown, send the 'org-trello-timer-go-to-sleep flag."
  `(condition-case ex
       (progn ,fn)
     ('error
      (orgtrello-log/msg *OT/ERROR* (concat "### org-trello - consumer ### Caught exception: [" ex "]"))
      (throw 'org-trello-timer-go-to-sleep t))))

(defun orgtrello-proxy/--getting-back-to-headline (data)
  "Trying another approach to getting back to header computing the normal form of an entry in the buffer."
  (orgtrello-proxy/--getting-back-to-marker (orgtrello/--compute-entity-to-org-entry data)))

(defun orgtrello-proxy/--compute-pattern-search-from-marker (marker)
  "Given a marker, compute the pattern to look for in the file."
  marker)

(defun orgtrello-proxy/--getting-back-to-marker (marker)
  "Given a marker, getting back to marker function. Move the cursor position."
  (goto-char (point-min))
  (re-search-forward (orgtrello-proxy/--compute-pattern-search-from-marker marker) nil t))

(defun orgtrello-proxy/--get-back-to-marker (marker data)
  "Getting back to the marker. Move the cursor position."
  (let ((goto-ok (orgtrello-proxy/--getting-back-to-marker marker)))
    (if goto-ok
        goto-ok
        (orgtrello-proxy/--getting-back-to-headline data))))

(defun orgtrello/id-p (id)
  "Is the string a trello identifier?"
  (and id (not (string-match-p (format "^%s-" *ORGTRELLO-MARKER*) id))))

(defun orgtrello-proxy/--standard-post-or-put-success-callback (entity-to-sync file-to-cleanup)
  "Return a callback function able to deal with the update of the buffer at a given position." ;;(debug)
  (lexical-let ((orgtrello-proxy/--entry-position    (orgtrello-query/--position entity-to-sync))
                (orgtrello-proxy/--entry-buffer-name (orgtrello-query/--buffername entity-to-sync))
                (orgtrello-proxy/--entry-file        file-to-cleanup)
                (orgtrello-proxy/--marker            (orgtrello-query/--marker entity-to-sync)))
    (cl-defun put-some-insignificant-name (&key data &allow-other-keys)
      (orgtrello-proxy/--safe-wrap-or-throw-error
       (let* ((orgtrello-proxy/--entry-new-id (orgtrello-query/--id data)))
         ;; switch to the right buffer
         (set-buffer orgtrello-proxy/--entry-buffer-name)
         ;; will update via tag the trello id of the new persisted data (if needed)
         (save-excursion
           ;; get back to the buffer and update the id if need be
           (let ((str-msg (when (orgtrello-proxy/--get-back-to-marker orgtrello-proxy/--marker data)
                                ;; now we extract the data
                                (let* ((orgtrello-proxy/--entry-metadata (orgtrello-data/metadata))
                                       (orgtrello-proxy/--entry-id       (orgtrello/--id orgtrello-proxy/--entry-metadata)))
                                  (if orgtrello-proxy/--entry-id ;; id already present in the org-mode file
                                      ;; no need to add another
                                      (concat "Entity '" (orgtrello/--name orgtrello-proxy/--entry-metadata) "' with id '" orgtrello-proxy/--entry-id "' synced!")
                                      (let ((orgtrello-proxy/--entry-name (orgtrello-query/--name data)))
                                        ;; not present, this was just created, we add a simple property
                                        (orgtrello-action/set-property *ORGTRELLO-ID* orgtrello-proxy/--entry-new-id)
                                        (concat "Newly entity '" orgtrello-proxy/--entry-name "' with id '" orgtrello-proxy/--entry-new-id "' synced!")))))))
             (orgtrello-proxy/--cleanup-and-save-buffer-metadata orgtrello-proxy/--entry-file orgtrello-proxy/--marker)
             (when str-msg (orgtrello-log/msg *OT/INFO* str-msg)))))))))

(defun orgtrello-proxy/--archived-scanning-dir (dir-name)
  "Given a filename, return the archived scanning directory"
  (format "%s/.scanning" dir-name))

(defun orgtrello-proxy/--archived-scanning-file (file)
  "Given a filename, return its archived filename if we were to move such file."
  (let ((dir-name (orgtrello-proxy/--archived-scanning-dir (file-name-directory file))))
    ;; return the name for the new file
    (format "%s/%s" dir-name (file-name-nondirectory file))))

(defun orgtrello-proxy/--archive-entity-file-when-scanning (file-to-archive file-archive-name)
  "Move the file to the running folder to specify a sync is running."
  (rename-file file file-archive-name t))

(defun orgtrello-proxy/--dispatch-action (action)
  (cond ((string= *ORGTRELLO-ACTION-DELETE* action) 'orgtrello-proxy/--delete)
        ((string= *ORGTRELLO-ACTION-SYNC*   action) 'orgtrello-proxy/--sync-entity)))

(defun orgtrello-proxy/--sync-entity (entity-data full-metadata entry-file-archived)
  "Execute the entity synchronization." ;;(debug)
  (let ((orgtrello-query/--query-map (orgtrello/--dispatch-create full-metadata)))
    ;; Execute the request
    (if (hash-table-p orgtrello-query/--query-map)
        ;; execute the request
        (orgtrello-query/http-trello
         orgtrello-query/--query-map
         *do-sync-query*
         (orgtrello-proxy/--standard-post-or-put-success-callback entity-data entry-file-archived)
         (cl-defun orgtrello-proxy/--standard-post-or-put-error-callback (&allow-other-keys)
           (orgtrello-log/msg *OT/ERROR* "Problem during sync!")
           (throw 'org-trello-timer-go-to-sleep t)))
        (progn
          (orgtrello-log/msg *OT/INFO* orgtrello-query/--query-map)
          (throw 'org-trello-timer-go-to-sleep t)))))

(defun orgtrello-proxy/--deal-with-entity-action (entity-data file-to-archive)
  "Compute the synchronization of an entity (retrieving latest information from buffer)"
  (let* ((op/--position                  (orgtrello-query/--position entity-data))                                   ;; position is mandatory
         (op/--buffer-name               (orgtrello-query/--buffername entity-data))                                 ;; buffer-name too
         (op/--entry-file-archived       (orgtrello-proxy/--archived-scanning-file file-to-archive))
         (op/--action-fn                 (orgtrello-proxy/--dispatch-action (orgtrello-query/--action entity-data))) ;; what's the running action?
         (op/--marker                    (orgtrello-query/--marker entity-data)))                                    ;; retrieve the marker
    (orgtrello-log/msg *OT/TRACE* "Proxy-consumer - Searching entity metadata from buffer '%s' at point '%s' to sync..." op/--buffer-name op/--position)
    ;; switch to the right buffer
    (set-buffer op/--buffer-name)
    ;; archive the scanned file
    (orgtrello-proxy/--archive-entity-file-when-scanning file-to-archive op/--entry-file-archived)
    ;; will update via tag the trello id of the new persisted data (if needed)
    (orgtrello-proxy/--safe-wrap-or-throw-error
     (save-excursion
       ;; Get back to the buffer's position to update
       (when (orgtrello-proxy/--getting-back-to-marker op/--marker)
             ;; do the actual action
             (funcall op/--action-fn entity-data (orgtrello-data/entry-get-full-metadata) op/--entry-file-archived))))))

;; (defun orgtrello/--compute-last-checkbox-sibling (level)
;;   "Compute the last checkbox sibling for the given level")

;; (defun orgtrello/--hide-subtree (level)
;;   "Hide the checklist's subtree"
;;   (hide-region-body (point) (orgtrello/--compute-last-checkbox-sibling level)))

(defun orgtrello-proxy/--standard-delete-success-callback (entity-to-del file-to-cleanup)
  "Return a callback function able to deal with the position."
  (lexical-let ((op/--entry-position    (orgtrello-query/--position entity-to-del))
                (op/--entry-buffer-name (orgtrello-query/--buffername entity-to-del))
                (op/--entry-level       (orgtrello-query/--level entity-to-del))
                (op/--entry-file        file-to-cleanup)
                (op/--marker            (orgtrello-query/--marker entity-to-del)))
    (lambda (&rest response)
      (orgtrello-action/safe-wrap
       (progn
         (set-buffer op/--entry-buffer-name)
         (save-excursion
           (when (orgtrello-proxy/--getting-back-to-marker op/--marker)
                 (unless (orgtrello-cbx/checkbox-p) (org-back-to-heading t))
                 (org-delete-property *ORGTRELLO-ID*)
                 (if (org-at-heading-p)
                     (hide-subtree)
                     (when (orgtrello-cbx/checkbox-p)
                           ;; (orgtrello/--hide-subtree op/--entry-level)
                           (org-cycle 'fold)))
                 (beginning-of-line)
                 (kill-line)
                 (kill-line))))
       (progn
         (save-buffer)
         (orgtrello-log/msg *OT/INFO* "Deleting entity in the buffer '%s' at point '%s' done!"
                            op/--entry-buffer-name
                            op/--entry-position))))))

(defun orgtrello-proxy/--delete (entity-data full-metadata entry-file-archived)
  "Execute the entity deletion."
  (let ((orgtrello-query/--query-map (orgtrello/--dispatch-delete (orgtrello-data/current full-metadata) (orgtrello-data/parent full-metadata))))
      (if (hash-table-p orgtrello-query/--query-map)
          (orgtrello-query/http-trello
           orgtrello-query/--query-map
           *do-sync-query*
           (orgtrello-proxy/--standard-delete-success-callback entity-data entry-file-archived))
          (progn
            (orgtrello-log/msg *OT/INFO* orgtrello-query/--query-map)
            (throw 'org-trello-timer-go-to-sleep t)))))

(defun orgtrello-proxy/--deal-with-entity-file-action (file)
  "Given an entity file, load it and run a query action through trello"
  (when (file-exists-p file)
        ;; extract the entity data
        (orgtrello-proxy/--deal-with-entity-action (-> file orgtrello-proxy/--read-lines read) file)))

(defun dictionary-lessp (str1 str2)
  "return t if STR1 is < STR2 when doing a dictionary compare (splitting the string at numbers and doing numeric compare with them)"
  (let ((str1-components (dict-split str1))
        (str2-components (dict-split str2)))
    (dict-lessp str1-components str2-components)))

(defun dict-lessp (slist1 slist2)
  "compare the two lists of strings & numbers"
  (cond ((null slist1)
         (not (null slist2)))
        ((null slist2)
         nil)
        ((and (numberp (car slist1))
              (stringp (car slist2)))
         t)
        ((and (numberp (car slist2))
              (stringp (car slist1)))
         nil)
        ((and (numberp (car slist1))
              (numberp (car slist2)))
         (or (< (car slist1) (car slist2))
             (and (= (car slist1) (car slist2))
                  (dict-lessp (cdr slist1) (cdr slist2)))))
        (t
         (or (string-lessp (car slist1) (car slist2))
             (and (string-equal (car slist1) (car slist2))
                  (dict-lessp (cdr slist1) (cdr slist2)))))))

(defun dict-split (str)
  "split a string into a list of number and non-number components"
  (save-match-data
    (let ((res nil))
      (while (and str (not (string-equal "" str)))
        (let ((p (string-match "[0-9]*\\.?[0-9]+" str)))
          (cond ((null p)
                 (setq res (cons str res))
                 (setq str nil))
                ((= p 0)
                 (setq res (cons (string-to-number (match-string 0 str)) res))
                 (setq str (substring str (match-end 0))))
                (t
                 (setq res (cons (substring str 0 (match-beginning 0)) res))
                 (setq str (substring str (match-beginning 0)))))))
      (reverse res))))

(defun orgtrello-proxy/--list-files (directory &optional sort-lexicographically)
  "Compute list of regular files (no directory . and ..). List is sorted lexicographically if sort-flag-lexicographically is set, naturally otherwise."
  (let ((orgtrello-proxy/--list-files-result (--filter (file-regular-p it) (directory-files directory t))))
    (unless sort-lexicographically
        orgtrello-proxy/--list-files-result
        (sort orgtrello-proxy/--list-files-result 'dictionary-lessp))))

(defun orgtrello-proxy/--deal-with-directory-action (level directory)
  "Given a directory, list the files and take the first one (entity) and do some action on it with trello. Call again if it remains other entities."
  (let ((orgtrello-proxy/--files (orgtrello-proxy/--list-files directory)))
    (when orgtrello-proxy/--files
          (orgtrello-proxy/--deal-with-entity-file-action (car orgtrello-proxy/--files))
          ;; if it potentially remains files, recall recursively this function
          (when (< 1 (length orgtrello-proxy/--files)) (orgtrello-proxy/--deal-with-level level directory)))))

(defun orgtrello-proxy/--level-done-p (level)
  "Is the level done"
  (-> level
      orgtrello-proxy/--compute-entity-level-dir
      orgtrello-proxy/--list-files
      null))

(defun orgtrello-proxy/--level-inf-done-p (level)
  "Ensure the actions of the lower level is done (except for level 1 which has no deps)!"
  (cond ((= 1 level) t)
        ((= 2 level) (orgtrello-proxy/--level-done-p 1))
        ((= 3 level) (and (orgtrello-proxy/--level-done-p 2) (orgtrello-proxy/--level-done-p 1)))))

(defun orgtrello-proxy/--deal-with-level (level directory)
 "Given a level, retrieve one file (which represents an entity) for this level and sync it, then remove such file. Then recall the function recursively."
 (if (orgtrello-proxy/--level-inf-done-p level)
     (orgtrello-proxy/--deal-with-directory-action level directory)
     (throw 'org-trello-timer-go-to-sleep t)))

(defun orgtrello-proxy/--deal-with-archived-files (level)
 "Given a level, retrieve one file (which represents an entity) for this level and sync it, then remove such file. Then recall the function recursively."
 (mapc (lambda (file) (rename-file file (format "../%s" (file-name-nondirectory file)) t)) (-> level
                                                                                               orgtrello-proxy/--compute-entity-level-dir
                                                                                               orgtrello-proxy/--archived-scanning-dir
                                                                                               orgtrello-proxy/--list-files)))

(defun orgtrello-proxy/--consumer-entity-files-hierarchically-and-do ()
  "A handler to extract the entity informations from files (in order card, checklist, items)." ;;(debug)
  ;; now let's deal with the entities sync in order with level
  (with-local-quit
    ;; if archived file exists, get them back in the queue before anything else
    (dolist (l *ORGTRELLO-LEVELS*) (orgtrello-proxy/--deal-with-archived-files l))
    ;; if some check regarding order fails, we catch and let the timer sleep for it the next time to get back normally to the upper level in order
    (catch 'org-trello-timer-go-to-sleep
      (dolist (l *ORGTRELLO-LEVELS*) (orgtrello-proxy/--deal-with-level l (orgtrello-proxy/--compute-entity-level-dir l))))))

(defun orgtrello-proxy/--compute-lock-filename ()
  "Compute the name of a lock file"
  (format "%s%s/%s" elnode-webserver-docroot "org-trello" "org-trello-already-scanning.lock"))

(defvar *ORGTRELLO-LOCK* (orgtrello-proxy/--compute-lock-filename) "Lock file to ensure one timer is running at a time.")

(defun orgtrello-proxy/--timer-put-lock (lock-file)
  "Start triggering the timer."
  (with-temp-file lock-file
    (insert "Timer - Scanning entities...")))

(defun orgtrello-proxy/--timer-delete-lock (lock-file)
  "Cleanup after the timer has been triggered."
  (orgtrello-proxy/--remove-file lock-file))

(defun orgtrello-proxy/--consumer-lock-and-scan-entity-files-hierarchically-and-do ()
  "A handler to extract the entity informations from files (in order card, checklist, items)."
  (undo-boundary)
  ;; only one timer at a time
  (orgtrello-action/safe-wrap
   (progn
     (orgtrello-proxy/--timer-put-lock *ORGTRELLO-LOCK*)
     (orgtrello-proxy/--consumer-entity-files-hierarchically-and-do))
   (orgtrello-proxy/--timer-delete-lock *ORGTRELLO-LOCK*))
  ;; undo boundary, to make a unit of undo
  (undo-boundary))

(defun orgtrello-proxy/--check-network-ok (&optional args)
  "Ensure there is some network running (simply check that there is more than the lo interface)."
  (if (< 1 (length (network-interface-list))) :ok "No network!"))

(defun orgtrello-proxy/--check-no-running-timer (&optional args)
  "Ensure there is not another running timer already."
  (if (file-exists-p (orgtrello-proxy/--compute-lock-filename)) "Timer already running!" :ok))

(defun orgtrello-proxy/--controls-and-scan-if-ok ()
  "Execution of the timer which consumes the entities and execute the sync to trello."
  (org-action/--msg-controls-or-actions-then-do
   "Scanning entities to sync"
   '(orgtrello-proxy/--check-network-ok orgtrello-proxy/--check-no-running-timer)
   'orgtrello-proxy/--consumer-lock-and-scan-entity-files-hierarchically-and-do
   nil ;; cannot save the buffer
   nil ;; do not need to reload the org-trello setup
   *do-not-display-log*));; do no want to log

(defun orgtrello-proxy/--prepare-filesystem ()
  "Prepare the filesystem for every level."
  (dolist (l *ORGTRELLO-LEVELS*)
    (-> l
        orgtrello-proxy/--compute-entity-level-dir
        orgtrello-proxy/--archived-scanning-dir
        (mkdir t))))

(defvar *ORGTRELLO-TIMER* nil "A timer run by elnode")

(defun orgtrello-proxy/--elnode-timer (http-con)
  "A process on elnode to trigger even regularly."
  (let* ((query-map     (orgtrello-proxy/--extract-trello-query http-con))
         (start-or-stop (orgtrello-query/--start query-map)))
    (if start-or-stop
        ;; cleanup before starting anew
        (progn
          (orgtrello-log/msg *OT/DEBUG* "Proxy-timer - Request received. Start timer.")
          ;; cleanup anything that the timer possibly left behind
          (orgtrello-proxy/--timer-delete-lock *ORGTRELLO-LOCK*)
          ;; Prepare the filesystem with the right folders
          (orgtrello-proxy/--prepare-filesystem)
          ;; start the timer
          (setq *ORGTRELLO-TIMER* (run-with-timer 0 5 'orgtrello-proxy/--controls-and-scan-if-ok)))
        ;; otherwise, stop it
        (when *ORGTRELLO-TIMER*
              (orgtrello-log/msg *OT/DEBUG* "Proxy-timer - Request received. Stop timer.")
              ;; stop the timer
              (cancel-timer *ORGTRELLO-TIMER*)
              ;; nil the orgtrello reference
              (setq *ORGTRELLO-TIMER* nil)))
    ;; ok in any case
    (orgtrello-proxy/response-ok http-con)))

(defun orgtrello-timer/start ()
  ;; cleanup anything that the timer possibly left behind
  (orgtrello-proxy/http-consumer t))

(defun orgtrello-timer/stop ()
  "Stop the orgtrello-timer."
  (orgtrello-proxy/http-consumer nil))



;; #################### orgtrello-admin

(require 'esxml)

(defun orgtrello-admin/--compute-root-static-files ()
  "Root files under which css and js files are installed."
  (format "%s%s" elnode-webserver-docroot "org-trello/bootstrap"))

(defun orgtrello-admin/--installation-needed-p ()
  "Determine if the installation is needed."
  (let ((dir (orgtrello-admin/--compute-root-static-files)))
    (not (and (file-exists-p dir)
              (< 3 (-> dir
                       directory-files
                       length)))))) ;; . and .. are returned by default

(defvar *ORGTRELLO-FILES* (let ((tmp (make-hash-table :test 'equal)))
                            ;;                    url                                                  temp file            install destination
                            (puthash :bootstrap `("http://getbootstrap.com/2.3.2/assets/bootstrap.zip" "/tmp/bootstrap.zip" ,(orgtrello-admin/--compute-root-static-files)) tmp)
                            (puthash :jquery    `("http://code.jquery.com/jquery-2.0.3.min.js"         "/tmp/jquery.js"     ,(format "%s/js" (orgtrello-admin/--compute-root-static-files))) tmp)
                            tmp))

(defun orgtrello-admin/--unzip-and-install (file dest)
  "Execute the unarchive command. Dependency on unzip on the system."
  (let ((ext (file-name-extension file)))
    (shell-command (format "unzip -o %s -d %s" file dest))))

(defun orgtrello-admin/--install-file (file file-dest)
  "Install the file from temporary location to the final destination."
  (when (file-exists-p file)
        (rename-file file file-dest t)))

(defun orgtrello-admin/--download-and-install-file (key-file)
  "Download the file represented by the parameter. Also, if the archive downloaded is a zip, unzip it."
  (let* ((url-tmp-dest (gethash key-file *ORGTRELLO-FILES*))
         (url          (first  url-tmp-dest))
         (tmp-dest     (second url-tmp-dest))
         (final-dest   (third  url-tmp-dest))
         (extension    (file-name-extension url)))
    ;; download the file
    (url-copy-file url tmp-dest t)
    (if (equal "zip" extension)
        (orgtrello-admin/--unzip-and-install tmp-dest (file-name-directory final-dest))
        (orgtrello-admin/--install-file tmp-dest final-dest))))

(defun orgtrello-admin/--install-css-js-files-once ()
  "Install bootstrap and jquery if need be."
  (when (orgtrello-admin/--installation-needed-p)
        (mapc (lambda (key-file) (orgtrello-admin/--download-and-install-file key-file)) '(:bootstrap :jquery))))

(defun orgtrello-admin/html ()
  "Main html page"
  (let ((project-name "org-trello/proxy-admin")
        (author-name  "Commiters")
        (description  "Administration the running queries to trello"))
    (esxml-to-xml
     `(html
       ()
       ,(orgtrello-admin/head project-name author-name description)
       ,(orgtrello-admin/body project-name)))))

(defun orgtrello-admin/head (project-name author-name description)
  "Generate html <head>"
  (esxml-to-xml
   `(head ()
          (meta ((charset . "utf-8")))
          (title () ,project-name)
          (meta ((name . "viewport")
                 (content . "width=device-width, initial-scale=1.0")))
          (meta ((name . "author")
                 (content . ,author-name)))
          (meta ((name . "description")
                 (content . ,description)))
          (style ()
                 "
      body {
        padding-top: 20px;
        padding-bottom: 40px;
      }

      /* Custom container */
      .container-narrow {
        margin: 0 auto;
        max-width: 700px;
      }
      .container-narrow > hr {
        margin: 30px 0;
      }

      /* Main marketing message and sign up button */
      .jumbotron {
        margin: 60px 0;
        text-align: center;
      }
      .jumbotron h1 {
        font-size: 72px;
        line-height: 1;
      }
      .jumbotron .btn {
        font-size: 21px;
        padding: 14px 24px;
      }

      /* Supporting marketing content */
      .marketing {
        margin: 60px 0;
      }
      .marketing p + h4 {
        margin-top: 28px;
      }")
          (link ((href . "/static/css/bootstrap.css")
                 (rel . "stylesheet")))
          (link ((href . "/static/css/bootstrap-responsive.min.css")
                 (rel . "stylesheet")))
          "
    <!-- HTML5 shim, for IE6-8 support of HTML5 elements -->
    <!--[if lt IE 9]>
      <script src=\"http://html5shim.googlecode.com/svn/trunk/html5.js\"></script>
    <![endif]-->
")))

(defun orgtrello-admin/body (project-name)
  "Display the data inside the html body"
  (esxml-to-xml
   `(body
     ()
     (div ((class . "navbar navbar-inverse navbar-fixed-top"))
          (div ((class . "navbar-inner"))
               (div ((class . "container"))
                    (button ((type . "button")
                             (class . "btn btn-navbar")
                             (data-toggle . "collapse")
                             (data-target . "nav-collapse"))
                            (span ((class . "icon-bar")))
                            (span ((class . "icon-bar")))
                            (span ((class . "icon-bar"))))
                    (a ((class . "brand")
                        (href . "#"))
                       ,project-name)
                    (div ((class . "nav-collapse collapse"))
                         (ul ((class . "nav"))
                             (li ((class . "active"))
                                 (a ((href . "#"))
                                    "Home"))
                             (li ((class . "active"))
                                 (a ((href . "#about"))
                                    "About"))
                             (li ((class . "active"))
                                 (a ((href . "#contact"))
                                    "Contact")))))))
     (div ((class . "container"))
          (div ((class . "container-narrow"))
               (div ((class . "row-fluid marketing"))
                    (div ((class . "span6"))
                         (h2 () "Current action")
                         (span ((id . "current-action"))))
                    (div ((class . "span6"))
                         (h2 () "Next actions")
                         (span ((id . "next-actions")))))))
     (script ((src . "/static/js/bootstrap.min.js")) "")
     (script ((src . "/static/js/jquery.js")) "")
     (script ()
             "
function refresh (url, id) {
    $.ajax({
        url: url
    }).done(function (data) {
        $(id).html(data);
        setTimeout(function() { refresh(url, id); }, 500);
    });
}

refresh(\"/proxy/admin/next-actions/\", '#next-actions');
refresh(\"/proxy/admin/current-action/\", '#current-action');
"))))

(defun orgtrello-admin/--content-file (file)
  "Return the content of a file (absolute name)."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun orgtrello-admin/--header-table ()
  "Generate headers"
  (esxml-to-xml `(tr
                  ()
                  (td ())
                  (td () "Action")
                  (td () "Entity"))))

(defun orgtrello-admin/--detail-entity (log-level entity-data)
  "Depending on the debug level, will display either the full entity data or simply its name."
  (if (= log-level 3) (orgtrello-query/--name entity-data) entity-data))

(defun orgtrello-admin/--entity (entity-content-file icon)
  "Compute the entity file display rendering."
  (esxml-to-xml
   `(tr
     ()
     (td () (i ((class . ,icon))))
     (td () ,(orgtrello-query/--action entity-content-file))
     (td () ,(format "%s" (orgtrello-admin/--detail-entity *orgtrello-log/level* entity-content-file))))))

(defun orgtrello-admin/--actions (content-files &optional icon-array-running icon-array-next)
  "Return the list of files to send to trello"
  (let ((fst-file       (car content-files))
        (rest-files     (cdr content-files))
        (icon-array-run (if icon-array-running icon-array-running "icon-arrow-right"))
        (icon-array-nxt (if icon-array-next icon-array-next "icon-arrow-up")))
    (if content-files
        (esxml-to-xml
         `(table ((class . "table table-striped table-bordered table-hover")
                  (style . "font-size: 0.75em"))
                 ;; header
                 ,(orgtrello-admin/--header-table)
                 ;; next running action
                 ,(orgtrello-admin/--entity fst-file icon-array-run)
                 ;; next running actions
                 ,(loop for entry-file in rest-files
                        concat
                        (orgtrello-admin/--entity entry-file icon-array-nxt))))
        "None")))

(defun orgtrello-proxy/--response-html (data http-con)
  "A response wrapper"
  (elnode-http-start http-con 201 '("Content-type" . "text/html"))
  (elnode-http-return http-con data))

(defun orgtrello-proxy/--elnode-admin (http-con)
  "A basic display of data"
  (orgtrello-proxy/--response-html (orgtrello-admin/html) http-con))

(defun compose-fn (funcs)
  "Composes several functions into one."
  (lexical-let ((intern-funcs funcs))
    (lambda (arg)
      (if intern-funcs
          (funcall (car intern-funcs)
                   (funcall (compose-fn (cdr intern-funcs)) arg))
          arg))))

(defun orgtrello-proxy/--elnode-actions (levels &optional scan-flag)
  "Compute the actions into list."
  (let* ((list-fns '(orgtrello-proxy/--compute-entity-level-dir))
         (scan-fns (if scan-flag (cons 'orgtrello-proxy/--archived-scanning-dir list-fns) list-fns)) ;; build the list of functions to create the composed function
         (composed-fn (compose-fn scan-fns)))
    (--map
     (read (orgtrello-admin/--content-file it))
     (--mapcat (orgtrello-proxy/--list-files (funcall composed-fn it)) levels))))

(defun orgtrello-proxy/--elnode-current-action (http-con)
  "A basic display of the list of entities to scan"
  (-> *ORGTRELLO-LEVELS*
      (orgtrello-proxy/--elnode-actions 'scan-folder)
      nreverse
      (orgtrello-admin/--actions "icon-play" "icon-pause")
      (orgtrello-proxy/--response-html http-con)))

(defun orgtrello-proxy/--elnode-next-actions (http-con)
  "A basic display of the list of entities to scan"
  (-> *ORGTRELLO-LEVELS*
       orgtrello-proxy/--elnode-actions
       orgtrello-admin/--actions
       (orgtrello-proxy/--response-html http-con)))

(defun orgtrello-proxy/--elnode-static-file (http-con)
  "Service static files if they exist"
  ;; the first request will ask for installing bootstrap and jquery
  (orgtrello-admin/--install-css-js-files-once)
  (let ((full-file (format "%s/%s/%s" (orgtrello-admin/--compute-root-static-files) (elnode-http-mapping http-con 1) (elnode-http-mapping http-con 2))))
    (if (file-exists-p full-file)
        (elnode-send-file http-con full-file)
        (elnode-send-404 http-con (format "Resource file '%s' not found!" full-file)))))



;; #################### orgtrello-proxy installation

(defvar *ORGTRELLO-QUERY-APP-ROUTES*
  '(;; proxy to request trello
    ("^localhost//proxy/admin/current-action/\\(.*\\)" . orgtrello-proxy/--elnode-current-action)
    ("^localhost//proxy/admin/next-actions/\\(.*\\)" . orgtrello-proxy/--elnode-next-actions)
    ("^localhost//proxy/admin/\\(.*\\)" . orgtrello-proxy/--elnode-admin)
    ;; proxy to request trello
    ("^localhost//proxy/trello/\\(.*\\)" . orgtrello-proxy/--elnode-proxy)
    ;; proxy producer to receive async creation request
    ("^localhost//proxy/producer/\\(.*\\)" . orgtrello-proxy/--elnode-proxy-producer)
    ;; proxy to request trello
    ("^localhost//proxy/timer/\\(.*\\)" . orgtrello-proxy/--elnode-timer)
    ;; static files
    ("^localhost//static/\\(.*\\)/\\(.*\\)" . orgtrello-proxy/--elnode-static-file))
  "Org-trello dispatch routes for the webserver")

(defun orgtrello-proxy/--proxy-handler (http-con)
  "Proxy handler."
  (elnode-hostpath-dispatcher http-con *ORGTRELLO-QUERY-APP-ROUTES*))

(defun orgtrello-proxy/--start (port host)
  "Starting the proxy."
  (orgtrello-log/msg *OT/TRACE* "Proxy-server starting...")
  (elnode-start 'orgtrello-proxy/--proxy-handler :port port :host host)
  (setq elnode--do-error-logging nil)
  (orgtrello-log/msg *OT/TRACE* "Proxy-server started!"))

(defun orgtrello-proxy/start ()
  "Start the proxy."
  ;; update with the new port the user possibly changed
  (setq *ORGTRELLO-PROXY-URL* (format "http://%s:%d/proxy" *ORGTRELLO-PROXY-HOST* *ORGTRELLO-PROXY-PORT*))
  ;; start the proxy
  (orgtrello-proxy/--start *ORGTRELLO-PROXY-PORT* *ORGTRELLO-PROXY-HOST*)
  ;; and the timer
  (orgtrello-timer/start))

(defun orgtrello-proxy/stop ()
  "Stopping the proxy."
  (orgtrello-log/msg *OT/TRACE* "Proxy-server stopping...")
  ;; stop the timer
  (orgtrello-timer/stop)
  ;; then stop the proxy
  (elnode-stop *ORGTRELLO-PROXY-PORT*)
  (orgtrello-log/msg *OT/TRACE* "Proxy-server stopped!"))

(defun orgtrello-proxy/reload ()
  "Reload the proxy server."
  (interactive)
  (orgtrello-proxy/stop)
  ;; stop the default port (only useful if the user changed from the default port)
  (elnode-stop *ORGTRELLO-PROXY-DEFAULT-PORT*)
  (orgtrello-proxy/start))

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello-proxy loaded!")



;; #################### orgtrello

;; Specific state - FIXME check if they do not already exist on org-mode to avoid potential collisions
(defvar *TODO* "TODO" "org-mode todo state")
(defvar *DONE* "DONE" "org-mode done state")

;; Properties key for the orgtrello headers #+PROPERTY board-id, etc...
(defvar *BOARD-ID*   "board-id" "orgtrello property board-id entry")
(defvar *BOARD-NAME* "board-name" "orgtrello property board-name entry")

(defvar *LIST-NAMES*   nil "orgtrello property names of the different lists. This use the standard 'org-todo-keywords property from org-mode.")
(defvar *HMAP-ID-NAME* nil "orgtrello hash map containing for each id, the associated name (or org keyword).")

(defvar *CONFIG-DIR*  (concat (getenv "HOME") "/" ".trello"))
(defvar *CONFIG-FILE* (concat *CONFIG-DIR* "/config.el"))

(defun orgtrello/filtered-kwds ()
  "org keywords used (based on org-todo-keywords-1)."
  org-todo-keywords-1)

(defun orgtrello/--setup-properties (&optional args)
  "Setup the properties according to the org-mode setup. Return :ok."
  ;; read the setup
  (orgtrello-action/reload-setup)
  ;; now exploit some
  (let* ((orgtrello/--list-keywords (nreverse (orgtrello/filtered-kwds)))
         (orgtrello/--hmap-id-name (cl-reduce
                                    (lambda (hmap name)
                                      (progn
                                        (puthash (assoc-default name org-file-properties) name hmap)
                                        hmap))
                                    orgtrello/--list-keywords
                                    :initial-value (make-hash-table :test 'equal))))
    (setq *LIST-NAMES*   orgtrello/--list-keywords)
    (setq *HMAP-ID-NAME* orgtrello/--hmap-id-name)
    :ok))

(defun orgtrello/--control-encoding (&optional args)
  "Use utf-8, otherwise, there will be trouble."
  (progn
    (orgtrello-log/msg *OT/ERROR* "Ensure you use utf-8 encoding for your org buffer.")
    :ok))

(defun orgtrello/--board-name ()
  "Compute the board's name"
  (assoc-default *BOARD-NAME* org-file-properties))

(defun orgtrello/--board-id ()
  "Compute the board's id"
  (assoc-default *BOARD-ID* org-file-properties))

(defun orgtrello/--control-properties (&optional args)
  "org-trello needs the properties board-id and all list id from the trello board to be setuped on header property file. Returns :ok if everything is ok, or the error message if problems."
  (let ((orgtrello/--hmap-count (hash-table-count *HMAP-ID-NAME*)))
    (if (and org-file-properties (orgtrello/--board-id) (= (length *LIST-NAMES*) orgtrello/--hmap-count))
        :ok
        "Setup problem.\nEither you did not connect your org-mode buffer with a trello board, to correct this:\n  * attach to a board through C-c o I or M-x org-trello/install-board-and-lists-ids\n  * or create a board from scratch with C-c o b or M-x org-trello/create-board).\nEither your org-mode's todo keyword list and your trello board lists are not named the same way (which they must).\nFor this, connect to trello and rename your board's list according to your org-mode's todo list.\nAlso, you can specify on your org-mode buffer the todo list you want to work with, for example: #+TODO: TODO DOING | DONE FAIL (hit C-c C-c to refresh the setup)")))

(defun orgtrello/--control-keys (&optional args)
  "org-trello needs the *consumer-key* and the *access-token* to access the trello resources. Returns :ok if everything is ok, or the error message if problems."
  (if (or (and *consumer-key* *access-token*)
          ;; the data are not set,
          (and (file-exists-p *CONFIG-FILE*)
               ;; trying to load them
               (load *CONFIG-FILE*)
               ;; still not loaded, something is not right!
               (and *consumer-key* *access-token*)))
      :ok
    "Setup problem - You need to install the consumer-key and the read/write access-token - C-c o i or M-x org-trello/install-board-and-lists-ids"))

(defun orgtrello/--keyword (entity-meta &optional default-value)
  "Retrieve the keyword from the entity. If default-value is specified, this is the default value if no keyword is present"
  (gethash :keyword entity-meta default-value))

(defun orgtrello/--name (entity-meta)
  "Retrieve the name from the entity."
  (gethash :name entity-meta))

(defun orgtrello/--id (entity-meta)
  "Retrieve the id from the entity (id must be a trello id, otherwise, it's not considered an id, it's the marker)."
  (let ((id (gethash :id entity-meta)))
    (when (orgtrello/id-p id) id)))

(defun orgtrello/--level (entity-meta)
  "Retrieve the level from the entity."
  (gethash :level entity-meta))

(defun orgtrello/--due (entity-meta)
  "Retrieve the due date from the entity."
  (gethash :due entity-meta))

(defun orgtrello/--buffername (entity-meta)
  "Retrieve the point from the entity."
  (gethash :buffername entity-meta))

(defun orgtrello/--position (entity-meta)
  "Retrieve the point from the entity."
  (gethash :position entity-meta))

(defun orgtrello/--retrieve-state-of-card (card-meta)
  "Given a card, retrieve its state depending on its :keyword metadata. If empty or no keyword then, its equivalence is *TODO*, otherwise, return its current state."
  (let* ((orgtrello/--card-kwd (orgtrello/--keyword card-meta *TODO*)))
    (if orgtrello/--card-kwd orgtrello/--card-kwd *TODO*)))

(defun orgtrello/--checks-before-sync-card (card-meta)
  "Checks done before synchronizing the cards."
  (let ((orgtrello/--card-name (orgtrello/--name card-meta)))
    (if orgtrello/--card-name
        :ok
      "Cannot synchronize the card - missing mandatory name. Skip it...")))

(defun orgtrello/--card (card-meta &optional parent-meta grandparent-meta)
  "Deal with create/update card query build. If the checks are ko, the error message is returned."
  (let ((checks-ok-or-error-message (orgtrello/--checks-before-sync-card card-meta)))
    ;; name is mandatory
    (if (equal :ok checks-ok-or-error-message)
        ;; parent and grandparent are useless here
        (let* ((orgtrello/--card-kwd  (orgtrello/--retrieve-state-of-card card-meta))
               (orgtrello/--list-id   (assoc-default orgtrello/--card-kwd org-file-properties))
               (orgtrello/--card-id   (orgtrello/--id    card-meta))
               (orgtrello/--card-name (orgtrello/--name card-meta))
               (orgtrello/--card-due  (orgtrello/--due   card-meta)))
          (if orgtrello/--card-id
              ;; update
              (orgtrello-api/move-card orgtrello/--card-id orgtrello/--list-id orgtrello/--card-name orgtrello/--card-due)
            ;; create
            (orgtrello-api/add-card orgtrello/--card-name orgtrello/--list-id orgtrello/--card-due)))
      checks-ok-or-error-message)))

(defun orgtrello/--checks-before-sync-checklist (checklist-meta card-meta)
  "Checks done before synchronizing the checklist."
  (let ((orgtrello/--checklist-name (orgtrello/--name checklist-meta))
        (orgtrello/--card-id        (orgtrello/--id card-meta)))
    (if orgtrello/--checklist-name
        (if orgtrello/--card-id
            :ok
          "Cannot synchronize the checklist - the card must be synchronized first. Skip it...")
      "Cannot synchronize the checklist - missing mandatory name. Skip it...")))

(defun orgtrello/--checklist (checklist-meta &optional card-meta grandparent-meta)
  "Deal with create/update checklist query build. If the checks are ko, the error message is returned."
  (let ((checks-ok-or-error-message (orgtrello/--checks-before-sync-checklist checklist-meta card-meta)))
    ;; name is mandatory
    (if (equal :ok checks-ok-or-error-message)
        ;; grandparent is useless here
        (let* ((orgtrello/--checklist-id   (orgtrello/--id checklist-meta))
               (orgtrello/--card-id        (orgtrello/--id card-meta))
               (orgtrello/--checklist-name (orgtrello/--name checklist-meta)))
          (if orgtrello/--checklist-id
              ;; update
              (orgtrello-api/update-checklist orgtrello/--checklist-id orgtrello/--checklist-name)
            ;; create
            (orgtrello-api/add-checklist orgtrello/--card-id orgtrello/--checklist-name)))
      checks-ok-or-error-message)))

(defun orgtrello/--checks-before-sync-item (item-meta checklist-meta card-meta)
  "Checks done before synchronizing the checklist."
  (let ((orgtrello/--item-name    (orgtrello/--name item-meta))
        (orgtrello/--checklist-id (orgtrello/--id checklist-meta))
        (orgtrello/--card-id      (orgtrello/--id card-meta)))
    (if orgtrello/--item-name
        (if orgtrello/--checklist-id
            (if orgtrello/--card-id
                :ok
              "Cannot synchronize the item - the card must be synchronized first. Skip it...")
          "Cannot synchronize the item - the checklist must be synchronized first. Skip it...")
      "Cannot synchronize the item - missing mandatory name. Skip it...")))

(defun orgtrello/--item-compute-state-or-check (checklist-update-items-p item-state checklist-state possible-states)
  "Compute the item's state/check (for creation/update). The 2 possible states are in the list possible states, first position is the 'checked' one, and second the unchecked one."
  (let* ((orgtrello/--item-checked   (first possible-states))
         (orgtrello/--item-unchecked (second possible-states)))
    (cond ((and checklist-update-items-p (string= *DONE* checklist-state))                      orgtrello/--item-checked)
          ((and checklist-update-items-p (or checklist-state (string= *TODO* checklist-state))) orgtrello/--item-unchecked)
          ((string= *DONE* item-state)                                                          orgtrello/--item-checked)
          (t                                                                                    orgtrello/--item-unchecked))))

(defun orgtrello/--item-compute-state (checklist-update-items-p item-state checklist-state)
  "Compute the item's state (for creation)."
  (orgtrello/--item-compute-state-or-check checklist-update-items-p item-state checklist-state '("complete" "incomplete")))

(defun orgtrello/--item-compute-check (checklist-update-items-p item-state checklist-state)
  "Compute the item's check status (for update)."
    (orgtrello/--item-compute-state-or-check checklist-update-items-p item-state checklist-state '(t nil)))

(defun orgtrello/--compute-state-from-keyword (state)
  "Given a state, compute the org equivalent (to use with org-todo function)"
  (if (string= *DONE* state) 'done 'none))

(defun orgtrello/--update-item-according-to-checklist-status (checklist-update-items-p checklist-meta)
  "Update the item of the checklist according to the status of the checklist."
  (if checklist-update-items-p
      (let ((orgtrello/--checklist-status (orgtrello/--compute-state-from-keyword (orgtrello/--keyword checklist-meta))))
        (org-todo orgtrello/--checklist-status))))

(defun orgtrello/--item (item-meta &optional checklist-meta card-meta)
  "Deal with create/update item query build. If the checks are ko, the error message is returned."
  (let ((checks-ok-or-error-message (orgtrello/--checks-before-sync-item item-meta checklist-meta card-meta)))
    ;; name is mandatory
    (if (equal :ok checks-ok-or-error-message)
        ;; card-meta is only usefull for the update part
        (let* ((orgtrello/--item-id      (orgtrello/--id item-meta))
               (orgtrello/--checklist-id (orgtrello/--id checklist-meta))
               (orgtrello/--card-id      (orgtrello/--id card-meta))
               (orgtrello/--item-name    (orgtrello/--name item-meta))
               (orgtrello/--item-state   (orgtrello/--keyword item-meta))
               (orgtrello/--checklist-state    (orgtrello/--keyword checklist-meta)))

          (orgtrello/--update-item-according-to-checklist-status *ORGTRELLO-CHECKLIST-UPDATE-ITEMS* checklist-meta)
          ;; update/create items
          (if orgtrello/--item-id
              ;; update - rename, check or uncheck the item
              (orgtrello-api/update-item orgtrello/--card-id orgtrello/--checklist-id orgtrello/--item-id orgtrello/--item-name (orgtrello/--item-compute-state *ORGTRELLO-CHECKLIST-UPDATE-ITEMS* orgtrello/--item-state orgtrello/--checklist-state))
            ;; create
            (orgtrello-api/add-items orgtrello/--checklist-id orgtrello/--item-name (orgtrello/--item-compute-check *ORGTRELLO-CHECKLIST-UPDATE-ITEMS* orgtrello/--item-state orgtrello/--checklist-state))))
      checks-ok-or-error-message)))

(defun orgtrello/--too-deep-level (meta &optional parent-meta grandparent-meta)
  "Deal with too deep level."
  "Your arborescence depth is too deep. We only support up to depth 3.\nLevel 1 - card\nLevel 2 - checklist\nLevel 3 - items")

(defun orgtrello/--dispatch-map-creation ()
  "Dispatch map for the creation of card/checklist/item. Key is the level of the entity, value is the create/update query map to sync such entity."
  (let* ((dispatch-map (make-hash-table :test 'equal)))
    (puthash 1 'orgtrello/--card      dispatch-map)
    (puthash 2 'orgtrello/--checklist dispatch-map)
    (puthash 3 'orgtrello/--item      dispatch-map)
    dispatch-map))

(defvar *MAP-DISPATCH-CREATE-UPDATE* (orgtrello/--dispatch-map-creation) "Dispatch map for the creation/update of card/checklist/item.")

(defun orgtrello/--dispatch-create (entry-metadata)
  "Dispatch the creation depending on the nature of the entry."
  (let* ((current-meta        (orgtrello-data/current entry-metadata))
         (current-entry-level (orgtrello/--level current-meta))
         (parent-meta         (orgtrello-data/parent entry-metadata))
         (grandparent-meta    (orgtrello-data/grandparent entry-metadata))
         (dispatch-fn         (gethash current-entry-level *MAP-DISPATCH-CREATE-UPDATE* 'orgtrello/--too-deep-level)))
    ;; then execute the call
    (funcall dispatch-fn current-meta parent-meta grandparent-meta)))

(defun orgtrello/--update-query-with-org-metadata (query-map position buffer-name &optional name success-callback sync)
  "Given a trello api query, add some metadata needed for org-trello to work (those metadata will be exploited by the proxy)."
  (puthash :position       position         query-map)
  (puthash :buffername     buffer-name      query-map)
  (when success-callback (puthash :callback success-callback query-map))
  (when sync             (puthash :sync     sync             query-map))
  (when name             (puthash :name     name             query-map))
  query-map)

(defun orgtrello/--set-marker (marker)
  "Set a marker to get back to later."
  (orgtrello-action/set-property *ORGTRELLO-ID* marker))

(defun orgtrello/--compute-marker-from-entry (entry)
  "Compute and set the marker (either a sha1 or the id of the entry-metadata)."
  (let ((orgtrello/--current-entry-id (orgtrello/--id entry)))
    (if orgtrello/--current-entry-id
        orgtrello/--current-entry-id
        (orgtrello/compute-marker (orgtrello/--buffername entry) (orgtrello/--name entry) (orgtrello/--position entry)))))

(defun orgtrello/--right-level-p (entity)
  "Compute if the level is correct (not higher than level 4)."
  (if (< (orgtrello/--level entity) 4) :ok "Level too high. Do not deal with entity other than card/checklist/items!"))

(defun orgtrello/--already-synced-p (entity)
  "Compute if the entity has already been synchronized."
  (if (orgtrello/--id entity) :ok "Entity must been synchronized with trello first!"))

(defun orgtrello/--delegate-to-the-proxy (entity action)
  "Execute the delegation to the consumer."
  (let ((orgtrello/--current-entry-id (orgtrello/--id entity))
        (orgtrello/--marker           (orgtrello/--compute-marker-from-entry entity)))
    ;; if never created before, we need a marker to add inside the file
    (unless (string= orgtrello/--current-entry-id orgtrello/--marker)
            (orgtrello/--set-marker orgtrello/--marker))
    ;; then we make the consumer aware of the marker
    (puthash :marker orgtrello/--marker entity)
    (puthash :action action             entity)
    ;; and send the data to the proxy
    (orgtrello-proxy/http-producer entity)))

(defun orgtrello/--checks-then-delegate-action-on-entity-to-proxy (functional-controls action)
  "Execute the functional controls then if all pass, delegate the action 'action' to the proxy."
  (let ((orgtrello/--entity (orgtrello-data/metadata)))
    (org-action/--functional-controls-then-do functional-controls orgtrello/--entity 'orgtrello/--delegate-to-the-proxy action)))

(defun orgtrello/do-delete-simple (&optional sync)
  "Do the deletion of an entity."
  (orgtrello/--checks-then-delegate-action-on-entity-to-proxy '(orgtrello/--right-level-p orgtrello/--already-synced-p) *ORGTRELLO-ACTION-DELETE*))

(defun orgtrello/do-sync-entity ()
  "Do the entity synchronization (if never synchronized, will create it, update it otherwise)."
  (orgtrello/--checks-then-delegate-action-on-entity-to-proxy '(orgtrello/--right-level-p) *ORGTRELLO-ACTION-SYNC*))

(defun orgtrello/do-sync-full-entity ()
  "Do the actual full card creation - from card to item. Beware full side effects..."
  (orgtrello-log/msg *OT/INFO* "Synchronizing full entity with its structure on board '%s'..." (orgtrello/--board-name))
  ;; iterate over the map of entries and sync them, breadth first
  (if (org-at-heading-p)
      (org-map-tree (lambda ()
                      ;; as usual we sync the heading
                      (orgtrello/do-sync-entity)
                      ;; we also sync the native checklist
                      (when *ORGTRELLO-NATURAL-ORG-CHECKLIST* (orgtrello/map-checkboxes 'orgtrello/do-sync-entity))))
      ;; we also sync the native checklist
      (when *ORGTRELLO-NATURAL-ORG-CHECKLIST* (orgtrello/map-checkboxes 'orgtrello/do-sync-entity))))

(defun orgtrello/do-sync-full-file ()
  "Full org-mode file synchronisation."
  (orgtrello-log/msg *OT/WARN* "Synchronizing org-mode file to the board '%s'. This may take some time, some coffee may be a good idea..." (orgtrello/--board-name))
  (org-map-entries
   (lambda ()
     ;; only sync the first level, the function orgtrello/do-sync-full-entity will take care of the rest #TODO need a function that permits to filter on level
     (when (= 1 (-> (orgtrello-data/entry-get-full-metadata) orgtrello-data/current orgtrello/--level))
                (orgtrello/do-sync-full-entity)))
   t
   'file))

(defun orgtrello/--compute-card-status (card-id-list)
  "Given a card's id, compute its status."
  (gethash card-id-list *HMAP-ID-NAME*))

(defun orgtrello/--compute-due-date (due-date)
  "Compute the format of the due date."
  (if due-date (format "DEADLINE: <%s>\n" due-date) ""))

(defun orgtrello/--private-compute-card-to-org-entry (name status due-date)
  "Compute the org format for card."
  (format "* %s %s\n%s" status name (orgtrello/--compute-due-date due-date)))

(defun orgtrello/--compute-card-to-org-entry (card &optional orgcheckbox-p)
  "Given a card, compute its org-mode entry equivalence. orgcheckbox-p is nil"
  (let* ((orgtrello/--card-name     (orgtrello-query/--name card))
         (orgtrello/--card-status   (orgtrello/--compute-card-status (orgtrello-query/--list-id card)))
         (orgtrello/--card-due-date (orgtrello-query/--due card)))
    (orgtrello/--private-compute-card-to-org-entry orgtrello/--card-name orgtrello/--card-status orgtrello/--card-due-date)))

(defun orgtrello/--compute-checklist-to-orgtrello-entry (name &optional level status)
  "Compute the orgtrello format checklist"
  (format "** %s\n" name))

(defun orgtrello/--symbol (sym n)
  "Compute the repetition of a symbol as a string"
  (--> n
       (-repeat it sym)
       (s-join "" it)))

(defun orgtrello/--space (n)
  "Given a level, compute the number of space for an org checkbox entry."
  (orgtrello/--symbol " "  n))

(defun orgtrello/--star (n)
  "Given a level, compute the number of space for an org checkbox entry."
  (orgtrello/--symbol "*"  n))

(defun orgtrello/--compute-state-generic (state list-state)
  "Computing generic."
  (if (string= "complete" state) (first list-state) (second list-state)))

(defun orgtrello/--compute-state-checkbox (state)
  "Compute the status of the checkbox"
  (orgtrello/--compute-state-generic state '("[X]" "[-]")))

(defun orgtrello/--compute-state-item (state)
  "Compute the status of the checkbox"
  (orgtrello/--compute-state-generic state '("DONE" "TODO")))

(defun orgtrello/--compute-level-into-spaces (level)
  "level 2 is 0 space, otherwise 2 spaces."
  (if (equal level 2) 0 2))

(defun orgtrello/--compute-checklist-to-org-checkbox (name &optional level status)
  "Compute the org checkbox format"
  (format "%s- %s %s\n"
          (-> level
              orgtrello/--compute-level-into-spaces
              orgtrello/--space)
          (orgtrello/--compute-state-checkbox status)
          name))

(defun orgtrello/--compute-item-to-orgtrello-entry (name &optional level status)
  (format "%s %s %s\n"
          (orgtrello/--star level)
          (orgtrello/--compute-state-item status)
          name))

(defun orgtrello/--compute-checklist-to-org-entry (checklist &optional orgcheckbox-p)
  "Given a checklist, compute its org-mode entry equivalence."
  (let ((o/--checklist-name   (orgtrello-query/--name checklist))
        (o/--checklist-status "incomplete")) ;; improve the compute the status from the checkbox below
    (funcall (if orgcheckbox-p
                 'orgtrello/--compute-checklist-to-org-checkbox
                 'orgtrello/--compute-item-to-orgtrello-entry)
             o/--checklist-name
             2
             o/--checklist-status)))

(defun orgrello/--compute-item-status (state)
  "Compute the status of the item given its status."
  (if (string= "complete" state) *DONE* *TODO*))

(defun orgtrello/--compute-item-to-org-entry (item &optional orgcheckbox-p)
  "Given a checklist item, compute its org-mode entry equivalence."
  (let ((orgtrello/--item-name  (orgtrello-query/--name  item))
        (orgtrello/--item-state (orgtrello-query/--state item)))
    (funcall (if orgcheckbox-p
                 'orgtrello/--compute-checklist-to-org-checkbox
                 'orgtrello/--compute-item-to-orgtrello-entry)
             orgtrello/--item-name
             3
             orgtrello/--item-state)))

(defun orgtrello/--card-p (entity)
  "Is this a card?"
  (orgtrello-query/--list-id entity))

(defun orgtrello/--checklist-p (entity)
  "Is this a checklist?"
  (orgtrello-query/--card-id entity))

(defun orgtrello/--item-p (entity)
  "is this an item?"
  (orgtrello-query/--state entity))

(defun orgtrello/--compute-entity-to-org-entry (entity)
  "Given an entity, compute its org representation."
  (trace :entity entity)
  (funcall
   (cond ((orgtrello/--card-p entity) 'orgtrello/--compute-card-to-org-entry)             ;; card      (level 1)
         ((orgtrello/--checklist-p entity) 'orgtrello/--compute-checklist-to-org-entry)   ;; checklist (level 2)
         ((orgtrello/--item-p entity)   'orgtrello/--compute-item-to-org-entry))          ;; items     (level 3)
   entity
   *ORGTRELLO-NATURAL-ORG-CHECKLIST*))

(defun orgtrello/--do-retrieve-checklists-from-card (card)
  "Given a card, return the list containing the card, the checklists from this card, and the items from the checklists. The order is guaranted."
  (cl-reduce
   (lambda (acc-list checklist-id)
     (let ((orgtrello/--checklist (orgtrello-query/http-trello (orgtrello-api/get-checklist checklist-id) *do-sync-query*)))
       (append (cons orgtrello/--checklist (orgtrello/--do-retrieve-checklists-and-items orgtrello/--checklist)) acc-list)))
   (orgtrello-query/--checklist-ids card)
   :initial-value nil))

(defun orgtrello/--do-retrieve-checklists-and-items (checklist)
  "Given a checklist id, retrieve all the items from the checklist and return a list containing first the checklist, then the items."
  (--map it (orgtrello-query/--check-items checklist)))

(defun orgtrello/--compute-full-entities-from-trello (cards)
  "Given a list of cards, compute the full cards data from the trello boards. The order from the trello board is now kept."
  ;; will compute the hash-table of entities (id, entity)
  (cl-reduce
   (lambda (orgtrello/--acc-hash orgtrello/--entity-card)
     (orgtrello-log/msg *OT/INFO* "Computing card '%s' data..." (orgtrello-query/--name orgtrello/--entity-card))
     ;; adding the entity card
     (puthash (orgtrello-query/--id orgtrello/--entity-card) orgtrello/--entity-card orgtrello/--acc-hash)
     ;; fill in the other remaining entities (checklist/items)
     (mapc
      (lambda (it)
        (puthash (orgtrello-query/--id it) it orgtrello/--acc-hash))
      (orgtrello/--do-retrieve-checklists-from-card orgtrello/--entity-card))
     orgtrello/--acc-hash)
   cards
   :initial-value (make-hash-table :test 'equal)))

(defun orgtrello/--update-property (id orgcheckbox-p)
  "Update the property depending on the nature of thing to sync. Move the cursor position."
  (if orgcheckbox-p
      (progn
        ;; need to get back one line backward for the checkboxes as their properties is at the same level (otherwise, for headings we do not care)
        (forward-line -1)
        (orgtrello-action/set-property *ORGTRELLO-ID* id)
        ;; getting back normally for the rest
        (forward-line))
      (orgtrello-action/set-property *ORGTRELLO-ID* id)))

(defun orgtrello/--write-entity (entity-id entity)
  "Write the entity in the buffer to the current position. Move the cursor position."
  (insert (orgtrello/--compute-entity-to-org-entry entity))
  (orgtrello/--update-property entity-id (and *ORGTRELLO-NATURAL-ORG-CHECKLIST*
                                              (not
                                               (orgtrello/--card-p entity)))))

(defun orgtrello/--update-buffer-with-remaining-trello-data (entities buffer-name)
  "Given a map of entities, dump those entities in the current buffer."
  (if entities ;; could be empty
      (with-current-buffer buffer-name
        ;; go at the end of the file
        (goto-char (point-max))
        ;; dump the remaining entities
        (maphash
         (lambda (orgtrello/--entry-new-id orgtrello/--entity)
           (orgtrello-log/msg *OT/INFO* "Synchronizing new entity '%s' with id '%s'..." (orgtrello-query/--name orgtrello/--entity) orgtrello/--entry-new-id)
           (orgtrello/--write-entity orgtrello/--entry-new-id orgtrello/--entity))
         entities)
        (goto-char (point-min))
        (org-sort-entries t ?o)
        (save-buffer))))

(defun orgtrello/--update-entry-to-org-buffer (entities)
  "Update entry to the org-buffer. Side effects on entities (entries are removed)."
  (save-excursion
    (-when-let (entry-metadata (orgtrello-data/entry-get-full-metadata)) ;; if level > 4, entry-metadata is not considered as this is not represented in trello board
               ;; will search 'entities' hash table for updates (do not compute diffs, take them as is)
               (let* ((orgtrello/--entity         (gethash :current entry-metadata))
                      (orgtrello/--entity-id      (orgtrello/--id orgtrello/--entity))
                      (orgtrello/--entity-updated (gethash orgtrello/--entity-id entities)))
                 (if orgtrello/--entity-updated
                     ;; found something, we update by squashing the current contents
                     (let* ((orgtrello/--entry-new-id    (orgtrello-query/--id   orgtrello/--entity-updated))
                            (orgtrello/--entity-due-date (orgtrello-query/--due  orgtrello/--entity-updated))
                            (orgtrello/--entry-new-name  (orgtrello-query/--name orgtrello/--entity-updated)))
                       ;; update the buffer with the new updates (there may be none but naively we will overwrite at the moment)
                       (orgtrello-log/msg *OT/INFO* "Synchronizing entity '%s' with id '%s'..." orgtrello/--entry-new-name orgtrello/--entry-new-id)
                       (org-show-entry)
                       (kill-whole-line)
                       (if orgtrello/--entity-due-date (kill-whole-line))
                       (orgtrello/--write-entity orgtrello/--entry-new-id orgtrello/--entity-updated)
                       ;; remove the entry from the hash-table
                       (remhash orgtrello/--entity-id entities)))))))

(defun orgtrello/--sync-buffer-with-trello-data (entities buffer-name)
  "Given all the entities, update the current buffer with those."
  (with-current-buffer buffer-name
    (org-map-entries
     (lambda ()
       ;; update the heading entry
       (orgtrello/--update-entry-to-org-buffer entities)
       ;; then the possible checkboxes
       (when *ORGTRELLO-NATURAL-ORG-CHECKLIST* (orgtrello/map-checkboxes (lambda () (orgtrello/--update-entry-to-org-buffer entities)))))
     t
     'file))
  ;; return the entities which has been dryed
  entities)

(defun orgtrello/--sync-buffer-with-trello-data-callback (buffername &optional position name)
  "Generate a callback which knows the buffer with which it must work. (this callback must take a buffer-name and a position)"
  (lexical-let ((buffer-name buffername))
    (cl-defun sync-from-trello-insignificant-callback-name (&key data &allow-other-keys)
      "Synchronize the buffer with the response data."
      (orgtrello-action/safe-wrap
       (progn
         (orgtrello-log/msg *OT/TRACE* "proxy - response data: %S" data)
         (let* ((orgtrello/--entities-hash-map  (orgtrello/--compute-full-entities-from-trello data)) ;; data is the cards
                (orgtrello/--remaining-entities (orgtrello/--sync-buffer-with-trello-data orgtrello/--entities-hash-map buffer-name)))
           (orgtrello/--update-buffer-with-remaining-trello-data orgtrello/--remaining-entities buffer-name)
           (orgtrello-log/msg *OT/INFO* "Synchronizing the trello board from trello - done!")))))))

(defun orgtrello/do-sync-full-from-trello (&optional sync)
  "Full org-mode file synchronisation. Beware, this will block emacs as the request is synchronous."
  (orgtrello-log/msg *OT/INFO* "Synchronizing the trello board '%s' to the org-mode file. This may take a moment, some coffee may be a good idea..." (orgtrello/--board-name))
  (orgtrello-proxy/http (orgtrello/--update-query-with-org-metadata
                         (orgtrello-api/get-cards (orgtrello/--board-id))
                         nil
                         (buffer-name)
                         nil
                         'orgtrello/--sync-buffer-with-trello-data-callback)
                        sync))

(defun orgtrello/--card-delete (card-meta &optional parent-meta)
  "Deal with the deletion query of a card"
  ;; parent is useless here
  (orgtrello-api/delete-card (orgtrello/--id card-meta)))

(defun orgtrello/--checklist-delete (checklist-meta &optional parent-meta)
  "Deal with the deletion query of a checklist"
  ;; parent is useless here
  (orgtrello-api/delete-checklist (orgtrello/--id checklist-meta)))

(defun orgtrello/--item-delete (item-meta &optional checklist-meta)
  "Deal with create/update item query build"
  (let* ((orgtrello/--item-id      (orgtrello/--id item-meta))
         (orgtrello/--checklist-id (orgtrello/--id checklist-meta)))
    (orgtrello-api/delete-item orgtrello/--checklist-id orgtrello/--item-id)))

(defun orgtrello/--dispatch-map-delete ()
  "Dispatch map for the deletion of card/checklist/item."
  (let* ((dispatch-map (make-hash-table :test 'equal)))
    (puthash 1 'orgtrello/--card-delete      dispatch-map)
    (puthash 2 'orgtrello/--checklist-delete dispatch-map)
    (puthash 3 'orgtrello/--item-delete      dispatch-map)
    dispatch-map))

(defvar *MAP-DISPATCH-DELETE* (orgtrello/--dispatch-map-delete) "Dispatch map for the deletion query of card/checklist/item.")

(defun orgtrello/--dispatch-delete (meta &optional parent-meta)
  (let* ((level       (orgtrello/--level meta))
         (dispatch-fn (gethash level *MAP-DISPATCH-DELETE* 'orgtrello/--too-deep-level)))
    (funcall dispatch-fn meta parent-meta)))

(defun orgtrello/--do-delete-card (&optional sync)
  "Delete the card."
  (when (= 1 (-> (orgtrello-data/entry-get-full-metadata) orgtrello-data/current orgtrello/--level))
        (orgtrello/do-delete-simple sync)))

(defun orgtrello/do-delete-entities (&optional sync)
  "Launch a batch deletion of every single entities present on the buffer."
  (org-map-entries (lambda () (orgtrello/--do-delete-card sync)) t 'file))

(defun orgtrello/--do-install-config-file (*consumer-key* *access-token*)
  "Persist the file config-file with the input of the user."
  (make-directory *CONFIG-DIR* t)
  (with-temp-file *CONFIG-FILE*
    (erase-buffer)
    (goto-char (point-min))
    (insert (format "(setq *consumer-key* \"%s\")\n" *consumer-key*))
    (insert (format "(setq *access-token* \"%s\")" *access-token*))
    (write-file *CONFIG-FILE* 't)))

(defun orgtrello/do-install-key-and-token ()
  "Procedure to install the *consumer-key* and the token for the user in the config-file."
  (interactive)
  (browse-url "https://trello.com/1/appKey/generate")
  (let ((orgtrello/--*consumer-key* (read-string "*consumer-key*: ")))
    (browse-url (format "https://trello.com/1/authorize?response_type=token&name=org-trello&scope=read,write&expiration=never&key=%s" orgtrello/--*consumer-key*))
    (let ((orgtrello/--access-token (read-string "Access-token: ")))
      (orgtrello/--do-install-config-file orgtrello/--*consumer-key* orgtrello/--access-token)
      "Install key and read/write access token done!")))

(defun orgtrello/--id-name (entities)
  "Given a list of entities, return a map of (id, name)."
  (let* ((id-name (make-hash-table :test 'equal)))
    (mapc (lambda (it) (puthash (orgtrello-query/--id it) (orgtrello-query/--name it) id-name)) entities)
    id-name))

(defun orgtrello/--name-id (entities)
  "Given a list of entities, return a map of (id, name)."
  (let* ((name-id (make-hash-table :test 'equal)))
    (mapc (lambda (it) (puthash (orgtrello-query/--name it) (orgtrello-query/--id it) name-id)) entities)
    name-id))

(defun orgtrello/--list-boards ()
  "Return the map of the existing boards associated to the current account. (Synchronous request)"
  (cl-remove-if-not
   (lambda (board) (equal :json-false (orgtrello-query/--close-property board)))
   (orgtrello-query/http-trello (orgtrello-api/get-boards) *do-sync-query*)))

(defun orgtrello/--list-board-lists (board-id)
  "Return the map of the existing list of the board with id board-id. (Synchronous request)"
  (orgtrello-query/http-trello (orgtrello-api/get-lists board-id) *do-sync-query*))

(defun orgtrello/--choose-board (boards)
  "Given a map of boards, display the possible boards for the user to choose which one he wants to work with."
  ;; ugliest ever
  (defvar orgtrello/--board-chosen nil)
  (setq orgtrello/--board-chosen nil)
  (let* ((str-key-val  "")
         (i            0)
         (i-id (make-hash-table :test 'equal)))
    (maphash (lambda (id name)
               (setq str-key-val (format "%s%d: %s\n" str-key-val i name))
               (puthash (format "%d" i) id i-id)
               (setq i (+ 1 i)))
             boards)
    (while (not (gethash orgtrello/--board-chosen i-id))
      (setq orgtrello/--board-chosen
            (read-string (format "%s\nInput the number of the board desired: " str-key-val))))
    (let* ((orgtrello/--chosen-board-id   (gethash orgtrello/--board-chosen i-id))
           (orgtrello/--chosen-board-name (gethash orgtrello/--chosen-board-id boards)))
      `(,orgtrello/--chosen-board-id ,orgtrello/--chosen-board-name))))

(defun orgtrello/--convention-property-name (name)
  "Use the right convention for the property used in the headers of the org-mode file."
  (replace-regexp-in-string " " "-" name))

(defun orgtrello/--delete-buffer-property (property-name)
  "A simple routine to delete a #+property: entry from the org-mode buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((current-point (search-forward property-name nil t)))
      (if current-point
          (progn
            (goto-char current-point)
            (beginning-of-line)
            (kill-line)
            (kill-line))))))

(defun orgtrello/--remove-properties-file (list-keywords &optional update-todo-keywords)
  "Remove the current org-trello properties"
  (with-current-buffer (current-buffer)
    (orgtrello/--delete-buffer-property (format "#+property: %s" *BOARD-ID*))
    (orgtrello/--delete-buffer-property (format "#+property: %s" *BOARD-NAME*))
    (mapc (lambda (name) (orgtrello/--delete-buffer-property (format "#+property: %s" (orgtrello/--convention-property-name name)))) list-keywords)
    (if update-todo-keywords
        (orgtrello/--delete-buffer-property "#+TODO: "))))

(defun orgtrello/--compute-keyword-separation (name)
  "Given a keyword done (case insensitive) return a string '| done' or directly the keyword"
  (if (string= "done" (downcase name)) (format "| %s" name) name))

(defun orgtrello/--update-orgmode-file-with-properties (board-name board-id board-lists-hash-name-id &optional update-todo-keywords)
  "Update the orgmode file with the needed headers for org-trello to work."
  (with-current-buffer (current-buffer)
    (goto-char (point-min))
    ;; force utf-8
    (set-buffer-file-coding-system 'utf-8-auto)
    ;; install board-name and board-id
    (insert (format "#+property: %s    %s\n" *BOARD-NAME* board-name))
    (insert (format "#+property: %s      %s\n" *BOARD-ID* board-id))
    ;; install the other properties regarding the org keywords
    (maphash
     (lambda (name id)
       (insert (format "#+property: %s %s\n" (orgtrello/--convention-property-name name) id)))
     board-lists-hash-name-id)
    (if update-todo-keywords
        (progn
          ;; install the todo list
          (insert "#+TODO: ")
          (maphash (lambda (name _) (insert (concat (orgtrello/--compute-keyword-separation (orgtrello/--convention-property-name name)) " "))) board-lists-hash-name-id)
          (insert "\n")))
    ;; save the buffer
    (save-buffer)
    ;; restart org to make org-trello aware of the new setup
    (orgtrello-action/reload-setup)))

(defun orgtrello/--hash-table-keys (hash-table)
  "Extract the keys from the hash table"
  (let ((keys ()))
    (maphash (lambda (k v) (push k keys)) hash-table)
    keys))

(defun orgtrello/do-install-board-and-lists ()
  "Interactive command to install the list boards"
  (interactive)
  (cl-destructuring-bind
      (orgtrello/--chosen-board-id orgtrello/--chosen-board-name) (-> (orgtrello/--list-boards)
                                                                      orgtrello/--id-name
                                                                      orgtrello/--choose-board)
    (let* ((orgtrello/--board-lists-hname-id (-> orgtrello/--chosen-board-id
                                                 orgtrello/--list-board-lists
                                                 orgtrello/--name-id))
           (orgtrello/--board-list-keywords (orgtrello/--hash-table-keys orgtrello/--board-lists-hname-id)))
      ;; remove any eventual present entry
      (orgtrello/--remove-properties-file orgtrello/--board-list-keywords t)
      ;; update with new ones
      (orgtrello/--update-orgmode-file-with-properties
       orgtrello/--chosen-board-name
       orgtrello/--chosen-board-id
       orgtrello/--board-lists-hname-id
       t))
    "Install board and list ids done!"))

(defun orgtrello/--create-board (board-name &optional board-description)
  "Create a board with name and eventually a description."
  (progn
    (orgtrello-log/msg *OT/INFO* "Creating board '%s'" board-name)
    (let* ((board-data (orgtrello-query/http-trello (orgtrello-api/add-board board-name board-description) *do-sync-query*)))
      (list (orgtrello-query/--id board-data) (orgtrello-query/--name board-data)))))

(defun orgtrello/--close-lists (list-ids)
  "Given a list of ids, close those lists."
  (mapc (lambda (list-id)
          (progn
            (orgtrello-log/msg *OT/INFO* "Closing default list with id %s" list-id)
            (orgtrello-query/http-trello (orgtrello-api/close-list list-id))))
        list-ids))

(defun orgtrello/--create-lists-according-to-keywords (board-id list-keywords)
  "Given a list of names, build those lists on the trello boards. Return the hashmap (name, id) of the new lists created."
  (cl-reduce
   (lambda (acc-hash-name-id list-name)
     (progn
       (orgtrello-log/msg *OT/INFO* "Board id %s - Creating list '%s'" board-id list-name)
       (puthash list-name (orgtrello-query/--id (orgtrello-query/http-trello (orgtrello-api/add-list list-name board-id) *do-sync-query*)) acc-hash-name-id)
       acc-hash-name-id))
   list-keywords
   :initial-value (make-hash-table :test 'equal)))

(defun orgtrello/do-create-board-and-lists ()
  "Interactive command to create a board and the lists"
  (interactive)
  (defvar orgtrello/--board-name nil)        (setq orgtrello/--board-name nil)
  (defvar orgtrello/--board-description nil) (setq orgtrello/--board-description nil)
  (while (not orgtrello/--board-name) (setq orgtrello/--board-name (read-string "Please, input the desired board name: ")))
  (setq orgtrello/--board-description (read-string "Please, input the board description (empty for none): "))
  (cl-destructuring-bind (orgtrello/--board-id orgtrello/--board-name) (orgtrello/--create-board orgtrello/--board-name orgtrello/--board-description)
                         (let* ((orgtrello/--board-list-ids       (--map (orgtrello-query/--id it) (orgtrello/--list-board-lists orgtrello/--board-id)))  ;; first retrieve the existing lists (created by default on trello)
                                (orgtrello/--lists-to-close       (orgtrello/--close-lists orgtrello/--board-list-ids))                                ;; close those lists (they may surely not match the name we want)
                                (orgtrello/--board-lists-hname-id (orgtrello/--create-lists-according-to-keywords orgtrello/--board-id *LIST-NAMES*))) ;; create the list, this returns the ids list
                           ;; remove eventual already present entry
                           (orgtrello/--remove-properties-file *LIST-NAMES*)
                           ;; update org buffer with new ones
                           (orgtrello/--update-orgmode-file-with-properties orgtrello/--board-name orgtrello/--board-id orgtrello/--board-lists-hname-id)))
  "Create board and lists done!")

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello loaded!")



;; #################### org-trello

(defun org-trello/sync-entity ()
  "Control first, then if ok, create a simple entity."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
     "Requesting entity sync"
     '(orgtrello/--setup-properties orgtrello/--control-keys orgtrello/--control-properties orgtrello/--control-encoding)
     'orgtrello/do-sync-entity))

(defun org-trello/sync-full-entity ()
  "Control first, then if ok, create an entity and all its arborescence if need be."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
     "Requesting entity and structure sync"
     '(orgtrello/--setup-properties orgtrello/--control-keys orgtrello/--control-properties orgtrello/--control-encoding)
     'orgtrello/do-sync-full-entity))

(defun org-trello/sync-to-trello ()
  "Control first, then if ok, sync the org-mode file completely to trello."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
     "Requesting sync org buffer to trello board"
     '(orgtrello/--setup-properties orgtrello/--control-keys orgtrello/--control-properties orgtrello/--control-encoding)
     'orgtrello/do-sync-full-file))

(defun org-trello/sync-from-trello ()
  "Control first, then if ok, sync the org-mode file from the trello board."
  (interactive)
  ;; execute the action
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
     "Requesting sync org buffer from trello board"
     '(orgtrello/--setup-properties orgtrello/--control-keys orgtrello/--control-properties orgtrello/--control-encoding)
     'orgtrello/do-sync-full-from-trello
     *do-save-buffer*))

(defun org-trello/kill-entity ()
  "Control first, then if ok, delete the entity and all its arborescence."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
     "Requesting deleting entity"
     '(orgtrello/--setup-properties orgtrello/--control-keys orgtrello/--control-properties orgtrello/--control-encoding)
     'orgtrello/do-delete-simple))

(defun org-trello/kill-all-entities ()
  "Control first, then if ok, delete the entity and all its arborescence."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
     "Requesting deleting entities"
     '(orgtrello/--setup-properties orgtrello/--control-keys orgtrello/--control-properties orgtrello/--control-encoding)
     'orgtrello/do-delete-entities))

(defun org-trello/install-key-and-token ()
  "No control, trigger the setup installation of the key and the read/write token."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
   "Setup key and token"
   nil
   'orgtrello/do-install-key-and-token
   *do-save-buffer*
   *do-reload-setup*))

(defun org-trello/install-board-and-lists-ids ()
  "Control first, then if ok, trigger the setup installation of the trello board to sync with."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
     "Install boards and lists"
     '(orgtrello/--setup-properties orgtrello/--control-keys)
     'orgtrello/do-install-board-and-lists
     *do-save-buffer*
     *do-reload-setup*))

(defun org-trello/create-board ()
  "Control first, then if ok, trigger the board creation."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
     "Create board and lists"
     '(orgtrello/--setup-properties orgtrello/--control-keys)
     'orgtrello/do-create-board-and-lists
     *do-save-buffer*
     *do-reload-setup*))

(defun org-trello/check-setup ()
  "Check the current setup."
  (interactive)
  (org-action/--controls-or-actions-then-do
     '(orgtrello/--setup-properties orgtrello/--control-keys orgtrello/--control-properties orgtrello/--control-encoding)
     (lambda () (orgtrello-log/msg *OT/NOLOG* "Setup ok!"))))

(defun orgtrello/--delete-property (property)
  ;; remove any identifier from the buffer
  (org-delete-property-globally *ORGTRELLO-ID*)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward ":PROPERTIES:.*" nil t)
      (replace-match "" nil t))))

(defun org-trello/delete-setup ()
  "Delete the current setup."
  (interactive)
  (org-action/--deal-with-consumer-msg-controls-or-actions-then-do
   "Deleting current org-trello setup"
     '(orgtrello/--setup-properties orgtrello/--control-keys orgtrello/--control-properties orgtrello/--control-encoding)
     (lambda ()
       ;; remove any orgtrello relative entries
       (orgtrello/--remove-properties-file *LIST-NAMES* t)
       ;; remove any identifier from the buffer
       (orgtrello/--delete-property *ORGTRELLO-ID*)
       ;; a simple message to tell the client that the work is done!
       (orgtrello-log/msg *OT/NOLOG* "Cleanup done!"))
     *do-save-buffer*
     *do-reload-setup*))

(defun org-trello/activate-natural-org-checkboxes ()
  "Activate the natural org-checkboxes - http://orgmode.org/manual/Checkboxes.html"
  (interactive)
  (setq *ORGTRELLO-NATURAL-ORG-CHECKLIST* t)
  (setq *ORGTRELLO-CHECKLIST-UPDATE-ITEMS* nil))

(defun org-trello/deactivate-natural-org-checkboxes ()
  "Activate the natural org-checkboxes - http://orgmode.org/manual/Checkboxes.html"
  (interactive)
  (setq *ORGTRELLO-NATURAL-ORG-CHECKLIST* nil)
  (setq *ORGTRELLO-CHECKLIST-UPDATE-ITEMS* t))

(defun org-trello/help-describing-bindings ()
  "A simple message to describe the standard bindings used."
  (interactive)
  (orgtrello-log/msg 0
"# SETUP RELATED
C-c o i - M-x org-trello/install-key-and-token       - Install the keys and the access-token.
C-c o I - M-x org-trello/install-board-and-lists-ids - Select the board and attach the todo, doing and done list.
C-c o d - M-x org-trello/check-setup                 - Check that the setup is ok. If everything is ok, will simply display 'Setup ok!'
C-c o D - M-x org-trello/delete-setup                - Clean up the org buffer from all org-trello informations
# TRELLO RELATED
C-c o b - M-x org-trello/create-board                - Create interactively a board and attach the org-mode file to this trello board.
C-c o c - M-x org-trello/sync-entity                 - Create/Update an entity (card/checklist/item) depending on its level and status. Do not deal with level superior to 4.
C-c o C - M-x org-trello/sync-full-entity            - Create/Update a complete entity card/checklist/item and its subtree (depending on its level).
C-c o s - M-x org-trello/sync-to-trello              - Synchronize the org-mode file to the trello board (org-mode -> trello).
C-c o S - M-x org-trello/sync-from-trello            - Synchronize the org-mode file from the trello board (trello -> org-mode).
C-c o k - M-x org-trello/kill-entity                 - Kill the entity (and its arborescence tree) from the trello board and the org buffer.
C-c o K - M-x org-trello/kill-all-entities           - Kill all the entities (and their arborescence tree) from the trello board and the org buffer.
# HELP
C-c o h - M-x org-trello/help-describing-bindings    - This help message."))

;;;###autoload
(define-minor-mode org-trello-mode "Sync your org-mode and your trello together."
  :lighter " ot" ;; the name on the modeline
  :keymap  (let ((map (make-sparse-keymap)))
             ;; setup relative
             (define-key map (kbd "C-c o i") 'org-trello/install-key-and-token)
             (define-key map (kbd "C-c o I") 'org-trello/install-board-and-lists-ids)
             (define-key map (kbd "C-c o d") 'org-trello/check-setup)
             (define-key map (kbd "C-c o x") 'org-trello/delete-setup)
             ;; synchronous request (direct to trello)
             (define-key map (kbd "C-c o b") 'org-trello/create-board)
             (define-key map (kbd "C-c o S") 'org-trello/sync-from-trello)
             ;; asynchronous requests (requests through proxy)
             (define-key map (kbd "C-c o c") 'org-trello/sync-entity)
             (define-key map (kbd "C-c o C") 'org-trello/sync-full-entity)
             (define-key map (kbd "C-c o k") 'org-trello/kill-entity)
             (define-key map (kbd "C-c o K") 'org-trello/kill-all-entities)
             (define-key map (kbd "C-c o s") 'org-trello/sync-to-trello)
             ;; Help
             (define-key map (kbd "C-c o h") 'org-trello/help-describing-bindings)
             map))

(add-hook 'org-trello-mode-on-hook
          (lambda ()
            ;; hightlight the properties of the checkboxes
            (font-lock-add-keywords 'org-mode '((": {\"orgtrello-id\":.*}" 0 font-lock-comment-face t)))
            ;; start the proxy
            (orgtrello-proxy/start)
            ;; a little message in the minibuffer to notify the user
            (orgtrello-log/msg *OT/NOLOG* "org-trello/ot is on! To begin with, hit C-c o h or M-x 'org-trello/help-describing-bindings")))

(add-hook 'org-trello-mode-off-hook
          (lambda ()
            ;; remove the highlight
            (font-lock-remove-keywords 'org-mode '((": {\"orgtrello-id\":.*}" 0 font-lock-comment-face t)))
            ;; stop the proxy
            (orgtrello-proxy/stop)
            ;; a little message in the minibuffer to notify the user
            (orgtrello-log/msg *OT/NOLOG* "org-trello/ot is off!")))

(orgtrello-log/msg *OT/DEBUG* "org-trello loaded!")

(provide 'org-trello)

;;; org-trello.el ends here
