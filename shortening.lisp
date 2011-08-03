(cl:defpackage #:shortening
  (:use #:cl #:alexandria #:hunchentoot #:py-configparser #:yaclml)
  (:export :init))
(cl:in-package #:shortening)

;; Config
(defparameter *port* 8181)
(defparameter *max-db-size* 100)
(defparameter *url-length* 6)

(defun load-config ()
  (when-let* ((config-path (probe-file (merge-pathnames ".shortening.conf" (user-homedir-pathname))))
              (config (handler-case (read-files (make-config) (list config-path))
                        (configparser-error () nil))))
    (flet ((conf (name)
             (ignore-errors (parse-integer (get-option config "conf" name)))))
      (setf *port* (or (conf "port") *port*)
            *max-db-size* (or (conf "max-db-size") *max-db-size*)
            *url-length* (or (conf "url-length") *url-length*)))
    t))

(defun ensure-config ()
  (let ((path (merge-pathnames ".shortening.conf" (user-homedir-pathname))))
    (unless (probe-file path)
      (with-open-file (fd path :direction :output :if-exists :supersede)
        (format fd "[default]~%port = ~A~%max-db-size = ~A~%url-length = ~A"
                *port* *max-db-size* *url-length*))
      t)))

;; Util
(defparameter *random-alphabet* "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
(defun random-string (&optional (length 6))
  (map-into (make-array length :element-type 'character)
            (lambda ()
              (elt *random-alphabet* (random (length *random-alphabet*))))))

;; DB
(defvar *url-db* nil)
(defstruct (url (:constructor make-url (expansion &optional origin))
                (:type list))
  expansion origin)

(defun find-url (short-url)
  (cdr (assoc short-url *url-db* :test #'string=)))

(defun truncate-db ()
  (when (> (length *url-db*) *max-db-size*)
    (setf *url-db* (subseq *url-db* 0 (1- (length *url-db*))))))

(defun unique-url ()
  (let ((url (concatenate 'string "/" (random-string *url-length*))))
    (if (or (find-url url) (string= url "/api"))
        (unique-url)
        url)))

(defun add-url (long-url &optional origin)
  (let ((short (unique-url)))
    (push (cons short (make-url long-url origin))
          *url-db*)
    (truncate-db)
    short))

;; server
(defun 404-handler ()
  (setf (return-code*) +http-not-found+)
  "Page not found")

(define-easy-handler (home :uri "/") ((plainp :parameter-type 'boolean))
  (if plainp
      (prin1 *url-db*)
      (with-yaclml-output-to-string
        (<:html :prologue "<!DOCTYPE html>"
                (<:body
                 (<:h1 "Links")
                 (<:ul
                  (loop for (short . url) in *url-db*
                     do (<:li (<:p (<:ah short) " - " (<:href (url-expansion url)
                                                              (<:ah (url-expansion url)))
                                   (when-let (origin (url-origin url))
                                     (<:ah " (origin: " origin ")")))))))))))

(define-easy-handler (api :uri "/api") (url origin)
  (setf (content-type*) "text/plain")
  (when url (add-url url origin)))

(defmacro exit-on-error (&body body)
  `(#+sbcl progn #+sbcl (setf sb-ext:*invoke-debugger-hook*
                              (lambda (c prev)
                                (declare (ignore prev))
                                (format *error-output* "~&~A~%" c)
                                (sb-ext:quit)))
    #+clisp ext:exit-on-error
    #-(or sbcl clisp) progn
    ,@body))

(defun init ()
  (exit-on-error
   (ensure-config)
   (load-config)
   (push (lambda (*request*)
           (unless (string= (script-name*) "/api")
             (when-let (target (find-url (script-name*)))
               (redirect target))))
         *dispatch-table*)
   (setf *default-handler* '404-handler)
   (pushnew +http-not-found+ *approved-return-codes*)
   (start (make-instance 'acceptor :port *port*
                         :taskmaster (make-instance 'single-threaded-taskmaster)))))
