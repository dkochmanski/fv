;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; fv.lisp -- (c) 2010, 2011, 2015 Antoni Grzymała
;;;
;;; This is my personal invoicing program, might only be useful in its
;;; current form in the Polish VAT-invoice area.
;;;

(in-package #:fv)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; for now, the useful public interface of this is limited to:
;;; (add-to-db) used in conjunction with:
;;;   (make-client)
;;;   (make-item)
;;;   (make-invoice) used in conjunction with:
;;;     (select-by-nick ...) or
;;;     (adjust-key (select-by-nick ...))
;;;
;;; (read-db)
;;; (write-db)
;;; (print-invoice) in conjunction with:
;;;   (select-invoice-by-id)
;;;
;;; remaning are helper functions and similar crap

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; TODO (in order of priority):
;;; + corrective invoices
;;; * removing entries from database
;;; * selecting invoices by certain criteria
;;; * interactive mode (text UI) with browsing clients/items
;;; * command-line switches for scripting
;;;
;;; --- later:
;;; * curses/tk/clim GUI
;;; * webgui
;;; * client/server (with android client)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; EXAMPLES:
;;; (make-invoice :client (select-by-nick :client 'asp)
;;;   :items (list (select-by-nick :item 'adminowanie-asp)))
;;; (make-invoice :client (select-by-nick :client 'asp)
;;;   :items (list
;;;            (adjust-key (select-by-nick :item 'adminowanie-asp) :count 2)
;;;            (select-by-nick :item 'coś-innego)))
;;; (add-to-db *)

;;; initialize the database and set default database filename:

(defvar *db* (list :item () :client () :invoice ()))

(defparameter *program-directory* (asdf:component-relative-pathname (asdf:find-system :fv)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *db-file* (merge-pathnames (user-homedir-pathname) #P".fvdb.lisp"))
  (defvar *rc-file* (merge-pathnames (user-homedir-pathname) #P".fvrc.lisp"))
  (load *rc-file*))

;;; and some system constants:

(setf *read-default-float-format* 'long-float)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Some needed functions
;;;

;;;
;;; following make-* functions return plists with our main types
;;; (item, client, invoice):
;;;

(defun make-item (&key title (vat 23) (count 1) net nick)
  "Create a single item inventory entry with a title, VAT, net price and nickname."
  (list
   :type  'item ; <- this tells us this is an item *db* entry
   :title title
   :vat   vat
   :count count
   :net   net
   :nick  nick))

(defun make-client (&key name address postcode (city "Warszawa")
                      nip email nick (default-item nil) (payment-days 7))
  "Create a client inventory item with name, address, postcode, city, nip, e-mail and nick"
  (list
   :type         'client ; <- this tells us this is a client *db* entry
   :name         name
   :address      address
   :postcode     postcode
   :city         city
   :nip          nip
   :email        email
   :nick         nick
   :default-item default-item
   :payment-days payment-days)) ; <- 0 means we want cash (7 is default)

(defun make-invoice (&key client items (payment-days 7)
                       year month date number (currency :pln))
  "Create an invoice with client, item list and date, payment
type (not nil for cash) and payment days."
  (let* ((universal-time (get-universal-time))
         (invoice-year   (or year   (getdate 'year  universal-time)))
         (invoice-month  (or month  (getdate 'month universal-time)))
         (invoice-date   (or date   (getdate 'date  universal-time)))
         (invoice-number (or number (get-highest-number :for-month invoice-month
                                                        :for-year invoice-year)))
         (invoice-id     (format nil "FV-~d/~d/~d" invoice-number invoice-month invoice-year)))
    ;; the above is to avoid a race-condition and make sure we create
    ;; a date in an atomic operation
    (when (or (null items)
              (not (listp (elt items 0))))
      (error "Item list should be a nested list: ((plist1) (plist2) (...))"))
    (list
     :type         'invoice
     :client       client
     :items        items
     :year         invoice-year
     :month        invoice-month
     :date         invoice-date
     :number       invoice-number
     :id           invoice-id
     :payment-days payment-days         ; <- 0 means we want cash
     :currency     currency)))

;;;
;;; return nearest possible invoice number (for a given month/year)
;;;

(defun get-highest-number (&key for-month for-year)
  "Return next usable invoice number for a given month/year based upon what's in the db."
  (let ((current-highest 0)
        (m for-month)
        (y for-year))
    (dolist (k (getf *db* :invoice))
      (cond ((and (eql (getf k :month) m)
                  (eql (getf k :year)  y))
             (if (<    current-highest (getf k :number))
                 (setf current-highest (getf k :number))
                 current-highest))))
    (1+ current-highest)))

;;;
;;; return some of today's date elements that are of interest to us
;;;

(defun getdate (what-we-want universal-time)
  "Return a decoded date element."
  ;; TODO: UTC → localtime
  (nth-value
   (position what-we-want
             '(second minute hour date month year day-of-week dst-p tz))
   (decode-universal-time universal-time)))

;;;
;;; return a database entry based upon nick and entry group (or an invoice by id)
;;; TODO -- maybe consolidate the two, they're practically identical
;;;

(defun select-by-nick (group nick)
  ;;(declare (optimize (debug 3)))
  "Returns an item or client matched by nick."
  (find nick (getf *db* group) :key (lambda (plist)
                                      (getf plist :nick))))

(defun select-invoice-by-id (id)
  "Returns an invoice when id is matched in the db."
  (dolist (k (getf *db* :invoice))
    (if (equal (getf k :id) id) ; equal!, we're comparing strings!
        (return k)
        nil)))

;;;
;;; function to adjust in-flight a key of a plist (with the intention
;;; of modifying :count when adding an item to an invoice
;;;

(defun adjust-key (plist key value)
  "Modify or add a field in a plist in place"
  (setf (getf plist key) value)
  plist)

;;;
;;; check if NIP identification number is correct and non-nil
;;;

(defun correct-nip-p (nip)
  "Check the NIP (VAT number) for correctness, expects an int"
  (let ((nip-string (format nil "~d" nip)))
    (when (= (length nip-string) 10)
      (let ((checksum (loop for w in '(6 5 7 2 3 4 5 6 7)
                         for i across nip-string
                         sum (* w (digit-char-p i)))))
        (= (digit-char-p (elt nip-string 9)) (rem checksum 11))))))

;;;
;;; add something to our database (returning the added item):
;;;

(defun add-to-db (entry &key (check-nip-p t))
  "Add anything to the db (in the right place) and do some verification tests."
  (let ((nick   (getf entry :nick))
        (nip    (getf entry :nip))
        (type   (getf entry :type))
        (id     (getf entry :id)))
    (cond
      ;; add an item
      ((equal type 'item)
       (when (or (select-by-nick nick :item)
                 (not nick))
         (error "~S already exists as an item nick or nick empty." nick))
       (push entry (getf *db* :item)) entry)
      ;; add a client and return it
      ((equal type 'client)
       (when (or (select-by-nick nick :client)
                 (not nick))
         (error "~S already exists as an item nick or nick empty." nick))
       (when (and check-nip-p
                  (or (not (correct-nip-p nip))
                      (not nip)))
         (error "~S is not a correct NIP number." nip))
       (push entry (getf *db* :client)) entry)
      ;; add an invoice and return it
      ((equal type 'invoice)
       (when (or (select-invoice-by-id id)
                 (not id))
         (error "~S already exists as an invoice id." id))
       (push entry (getf *db* :invoice)) entry)
      (t nil))
    entry)) ; return the entry itself if added successfully (instead of *db*)

;;;
;;; dump stuff function
;;;

(defun dump-db (type &optional field)
  "Quick view of the db (selected by type)"
  (dolist (entry (getf *db* type))
    (format t "~{~a:~10t~a~%~}~%" (if field
                                      (list field (getf entry field)) ;; 
                                      entry))))

;;;
;;; saving and loading the db
;;;

(defun write-db (&optional (pathname *db-file*))
  "Saves the invoice/client/item database to a file."
  (with-open-file (output pathname
                          :direction :output
                          :if-exists :supersede)
    (with-standard-io-syntax
      (write *db* :case :downcase :pretty t :stream output) ; pretty-print database contents
      (format output "~%"))))                               ; add trailing newline

(defun read-db (&optional (pathname *db-file*))
  "Loads the invoice/client/item database from a file"
  (let ((*read-eval* nil))
    (with-open-file (input pathname
                           :direction         :input
                           :if-does-not-exist :create)
      (with-standard-io-syntax
        (let ((*package* (find-package :fv)))
          (setf *db* (read input nil nil))))))
  '*db*)

(defmacro with-db ((&optional (pathname *db-file*)) &body body)
  `(progn
     (read-db ,pathname)
     ,@body
     (write-db ,pathname)))

(defparameter *currencies* '((:eur "euro" "euro" "euro")
                             (:pln "złoty" "złote" "złotych")
                             (:usd "dolar" "dolary" "dolarów")))

(defun get-currency-short (currency)
  (ecase currency
    (:eur "\\€")
    (:usd "usd")
    (:pln "zł")))

(defun get-account-number (currency)
  (or (case currency
        (:pln (or (getf *company-data* :account-pln)
                  (getf *company-data* :account)))
        (:eur (getf *company-data* :account-eur))
        (:usd (getf *company-data* :account-usd)))
      (warn "Foreign Currency Account not defined. Using polish one.")
      (getf *company-data* :account)
      (getf *company-data* :account-pln)))

(defun print-currency (gross-total stream &optional (currency :pln))
  ;; backward compatibility
  (unless currency
    (setf currency :pln))
  (let ((words (cdr (assoc currency *currencies*))))
    (format stream " ~a"
            (multiple-value-bind (tens ones)
                (truncate gross-total 10)
              (if (and (= tens 0) (= ones 1))
                (first words)
                  (case ones
                    ((2 3 4) (second words))
                    (otherwise (third words))))))))

;;;
;;; calculate all necessary invoice fields
;;;

(defun calculate-invoice-fields (invoice)
  "Returns a plist with calculations of various invoice fields needed
for invoice visualisation and printout."
  (let* ((gross-total       0) ;; do we need to declare all those here?
         (gross-total-int   0)
         (gross-total-cent  0)
         (net-total         0)
         (vat-total         0)
         (words-gross-total "")
         (payment-days      (getf invoice :payment-days))
         (invoice-date      (getf invoice :date))
         (invoice-month     (getf invoice :month))
         (invoice-year      (getf invoice :year))
         (invoice-currency  (getf invoice :currency))
         (payment-form      "")
         (23-net-total      0)
         (23-vat-total      0)
         (23-gross-total    0)
         (8-net-total       0)
         (8-vat-total       0)
         (8-gross-total     0)
         (5-net-total       0)
         (5-vat-total       0)
         (5-gross-total     0)
         (zw-net-total      0)
         (item-position     1)
         (calculated-items  nil))
    (dolist (item (getf invoice :items)) ;; <- *should* be a list
      (let* ((item-vat       (getf item :vat))
             (item-count     (getf item :count))
             (item-title     (getf item :title))
             (item-net       (getf item :net))
             (vat-multiplier (/ (if (equal item-vat "zw") ;; the "zw" (zwolniony)
                                    0         ;; VAT rate is
                                    item-vat) ;; effectively 0%
                                100))) ;; TODO -- check if interger here OK
        (cond ((equal item-vat 23)
               (incf 23-net-total   (* item-count item-net))
               (incf 23-vat-total   (* item-count item-net 0.23))
               (incf 23-gross-total (* item-count item-net 1.23)))
              ((equal item-vat 8)
               (incf 8-net-total    (* item-count item-net))
               (incf 8-vat-total    (* item-count item-net 0.08))
               (incf 8-gross-total  (* item-count item-net 1.08)))
              ((equal item-vat 5)
               (incf 5-net-total    (* item-count item-net))
               (incf 5-vat-total    (* item-count item-net 0.05))
               (incf 5-gross-total  (* item-count item-net 1.05)))
              ((equal item-vat "zw")
               (incf zw-net-total   (* item-count item-net))))
        (push (list item-position
                    item-title
                    (polish-monetize item-net)
                    item-count
                    (polish-monetize (* item-net item-count))
                    (if (equal item-vat "zw") "zw."
                        (format nil "~d\\%" item-vat))
                    (polish-monetize (* item-net item-count vat-multiplier))
                    (polish-monetize (* item-net item-count (1+ vat-multiplier))))
              calculated-items)
        (incf item-position)))

    (setf gross-total (+ 23-gross-total 8-gross-total 5-gross-total zw-net-total))
    (setf net-total   (+ 23-net-total   8-net-total   5-net-total   zw-net-total))
    (setf vat-total   (+ 23-vat-total   8-vat-total   5-vat-total))

    ;;; beware of floor (not used below anymore), rounding errors bite
    (multiple-value-bind (int cent)
        (delimited-substrings (format nil "~$" gross-total) '(#\.)) ; thx, Erik
      (setf gross-total-int  (read-from-string int))
      (setf gross-total-cent (read-from-string cent)))

    (setf words-gross-total
          (with-output-to-string (words)
            (format-print-cardinal words gross-total-int)
            (print-currency gross-total-int words invoice-currency)))

    (setf payment-form
          (if (<= payment-days 0)
              "Płatne gotówką."
              (multiple-value-bind (a b c day month year d e f)
                  (decode-universal-time
                   (+ (* payment-days 86400)
                      (encode-universal-time
                       0 0 0 invoice-date invoice-month invoice-year)))
                ;; TODO: UTC -> localtime
                (declare (ignore a b c d e f))
                (format nil
                        "Płatne przelewem do dnia: ~d/~d/~d (~d dni)."
                        day month year payment-days))))

    ;; now we return all we calculated in a single plist:
    (list :gross-total       (polish-monetize gross-total)
          :gross-total-int   gross-total-int
          :gross-total-cent  gross-total-cent
          :net-total         (polish-monetize net-total)
          :vat-total         (polish-monetize vat-total)
          :words-gross-total words-gross-total
          :payment-days      payment-days
          :invoice-date      invoice-date
          :invoice-month     invoice-month
          :invoice-year      invoice-year
          :currency  invoice-currency
          :payment-form      payment-form
          :23-net-total      (polish-monetize 23-net-total)
          :23-vat-total      (polish-monetize 23-vat-total)
          :23-gross-total    (polish-monetize 23-gross-total)
          :8-net-total       (polish-monetize 8-net-total)
          :8-vat-total       (polish-monetize 8-vat-total)
          :8-gross-total     (polish-monetize 8-gross-total)
          :5-net-total       (polish-monetize 5-net-total)
          :5-vat-total       (polish-monetize 5-vat-total)
          :5-gross-total     (polish-monetize 5-gross-total)
          :zw-net-total      (polish-monetize zw-net-total)
          :calculated-items  (reverse calculated-items))))

;;;
;;; Convert a float to a string with 2 decimal places, and a decimal comma
;;; How about using: (format nil "~,,'.,3:D" number)? Or something…
;;;

(defun polish-monetize (value)
  "Convert a float to a properly rounded string (to cents) with a
decimal comma and thousand dot separators."
  (multiple-value-bind (quot rem) (truncate value)
    (format nil "~,,'.:d,~2,'0d"
            quot
            (round (rational (abs rem)) 1/100))))

;;; printing an invoice (and optionally mailing it)
;;;

(defvar *fv-dir* (user-homedir-pathname))

(defun print-invoice (invoice &key mail (fv-dir *fv-dir*) (invoice-title "Faktura VAT"))
  "Creates a tex printout file of a given invoice by means of
executing emb code in a tex template.

If told to, mails the invoice to the email address defined for the
client."
  (let* ((env-plist
          (list :invoice-id        (getf invoice :id)
                :invoice-date-full (format nil "~a/~a/~a"
                                           (getf invoice :date)
                                           (getf invoice :month)
                                           (getf invoice :year))
                :seller-name       (getf *company-data* :name)
                :seller-address    (getf *company-data* :address)
                :seller-postcode   (getf *company-data* :postcode)
                :seller-city       (getf *company-data* :city)
                :seller-nip        (getf *company-data* :nip)
                :seller-account    (get-account-number (getf invoice :currency))
                :buyer-name        (getf (getf invoice :client) :name)
                :buyer-address     (getf (getf invoice :client) :address)
                :buyer-city        (getf (getf invoice :client) :city)
                :buyer-postcode    (getf (getf invoice :client) :postcode)
                :buyer-nip         (getf (getf invoice :client) :nip)
                :item-list         (getf invoice :items)
                :currency-short (get-currency-short (getf invoice :currency))
                :invoice-title invoice-title))
         (output-filename (merge-pathnames
                           fv-dir
                           (format nil
                                   (if (getf invoice :corrective)
                                       "fk-~d-~2,'0d-~2,'0d-~a.tex"
                                       "fv-~d-~2,'0d-~2,'0d-~a.tex")
                                   (getf invoice :year)
                                   (getf invoice :month)
                                   (getf invoice :number)
                                   (getf (getf invoice :client) :nick)))))
    (emb:register-emb "template"
                      (merge-pathnames *program-directory*
                                       (make-pathname :name
                                                      (if (getf invoice :corrective)
                                                          "fk-emb-template"
                                                          "fv-emb-template")
                                                      :type "tex")))
    (with-open-file (output output-filename
                            :direction :output
                            :if-exists :supersede)
      (format output "~a"
              (emb:execute-emb "template"
                               :env (append env-plist
                                            (calculate-invoice-fields invoice)))))
    #-unix
    (Error "Windows is not supported")
    (let ((command (format nil "pdflatex -output-directory=~a ~a" fv-dir
                           (namestring output-filename))))
      (format t "DEBUG: Running pdflatex... ~A" command)
      (when (zerop (nth-value 2 (uiop:run-program command)))
        (princ "Success!")
        (dolist (extension (list "aux" "log" "tex"))
          (delete-file (make-pathname :type extension :defaults output-filename)))
        (when (and
               mail
               (getf (getf invoice :client) :email)) ; and email address available
          (princ "DEBUG: Sending e-mail...")
          (uiop:run-program
           (format nil "mailx ~{~a~^ ~}"
                   (list "-a" (namestring (merge-pathnames
                                           *program-directory*
                                           ;; message body
                                           (make-pathname :name "email-template"
                                                          :type "txt")))
                         ;; PDF attachment
                         "-a" (namestring (make-pathname :type "pdf"
                                                         :defaults output-filename))
                         "-r" (format nil "~a <~a>"
                                      (getf *company-data* :name)
                                      (getf *company-data* :email))
                         "-s" (format nil "Faktura od ~a za ~a/~a"
                                      (getf *company-data* :name)
                                      (getf invoice :month)
                                      (getf invoice :year))
                         "-b" (getf *company-data* :email) ; bcc copy to self
                         (getf (getf invoice :client) :email)))))))))

;;;
;;; quick billing based on nicks (and default items)
;;;

(defun bill (client &rest items) ;; TODO: Convert to typecase
  ;; 00:34:35 < drewc> (and (not (null foo)) (typep foo 'list)) = (consp foo)
  (make-invoice
   :client (select-by-nick :client client)
   :items  (let ((spliced-items (car items)))
             (cond ((and
                     (listp spliced-items)
                     (not (null spliced-items)))
                    spliced-items)
                   ((and
                     (atom spliced-items)
                     (not (null spliced-items)))
                    (list (select-by-nick :item spliced-items)))
                   (t
                    (list (select-by-nick :item
                                          (getf (select-by-nick :client client)
                                                :default-item))))))))

;;
;; monthly billing for clients billed monthly
;;

(defun last-day-of-month-p ()
  "Helper function to check whether we have a billing date (last day of month)."
  ;; TODO: UTC → localtime
  (let* ((last-days     #(31 28 31 30 31 30 31 31 30 31 30 31))
         (universal-time (get-universal-time))
         (date           (getdate 'date  universal-time))
         (month          (getdate 'month universal-time))
         #|(year           (getdate 'year  universal-time))|#)
    (or (and (= date 29) (= month 2))
        (= date (aref last-days (1- month))))))

(defun bill-monthly (&optional force)
  "Automatically bill clients that receive regular monthly billing (on last day of month)."
  ;; reads and writes the db (destructively)
  (when (or (last-day-of-month-p) force)
    (read-db)
    (dolist (client *monthly-billed-clients*) ; list read from rc-file
      (let ((invoice (bill client)))
        (add-to-db invoice)
        (print-invoice invoice :mail t)))
    (write-db)))
