;;; aes.el --- Implementation of AES in emacs lisp

;; Copyright (C) 2008 Markus Sauermann

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE.  See the GNU General Public License for more details.

;; You should have received a copy of the GNU General Public
;; License along with this program; if not, write to the Free
;; Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301 USA

;; Author: Markus Sauermann <mhoram@glory.to>
;; Maintainer: Markus Sauermann <mhoram@glory.to>
;; Created: 15 Feb 2008
;; Version: 0.2
;; Revision: $Id: aes.el 27 2008-09-26 01:25:01Z mhoram $
;; Keywords: data tools

;;; Change Log:

;; 0.1 initial working unpublished version
;; 0.2 performance enhancements
;;     documentation included

;;; Commentary:

;; Configfile
;; Insert "(require 'aes)" into your local .emacs file to load this library.
;; Insert "(aes-enable-auto-decryption)" into yout local .emacs file for
;; convenient automatic recoginzation of encrypted files during loading.

;; Whenever possible, this library should be used byte-compiled, as this
;; provides a great performance boost!

;; Main entry functions:
;; `aes-encrypt-current-buffer' ask for password and encrypt current buffer
;; `aes-decrypt-current-buffer' ask for password and decrypt current buffer
;; `aes-insert-password' Generate a random password from user input
;; For customizing this library, there is the customization group aes in the
;; applications group.

;; Emacs version 22 is recommended. It should work with version 21, but there
;; mightbe some incompatible hooks used for automatic decryption.

;; This library implements the Rijndael algorithm [1] natively! in emacs.
;; This is a superset of the AES algorithm [2].
;; Further this library contains implementations of Cipher-block chaining [4]
;; and Offset Codebook Mode [5].
;; For patent issues about OCB see [6], which allows this distribution.
;; This library allows to encrypt and decrypt buffers or strings.

;; This implementation allows additionally to the AES specification blocklengths
;; of 24 and 32 bytes.

;; Nb denotes the number of 32-bit words in the state.
;; Nk denotes the number of 32-bit words comprising the cipher key.
;; Nr denotes the number of rounds.
;; We allow Nb and Nk to be 4, 6, or 8. and Nr = max(Nb, Nk) + 6

;; Since emacs implements integers as 29 bit numbers, it is not possible to
;; use the best possible optimization, which requires 32 bit numbers. For
;; details see [3].
;; This leads to the usage of an 8-bit design for this implementation.
;; So it was necessary to find fitting implementations.
;; - Multiplication and Inverting in GF(2^8) are implemented as a table lookups.
;; - The state is implemented as a string of length 4 * Nb.
;; - Plaintext and ciphertext are implemented as unibyte strings.
;; - The expanded key is implemented as a list of length 4 * Nb * (1 + Nr)
;;   with entries '((A . B) . (C . D)), where A, B, C and D are integers between
;;   0 and 255 inclusive. It is precalculated before the usage of AES.
;;   For decryption it is necessary to introduce an extended representation
;;   of the expanded key, since the application of the keys is against the
;;   internal stored order and emacs makes travelling a list in the opposite
;;   direction not easy.
;; - The S-boxes are implemented by lookup tables.
;; - The three operations ByteSub, ShiftRow and MixColumn together with Round
;;   key-addition are implemented in the single function `aes-SubShiftMixKeys'
;;   and `aes-InvSubShiftMixKeys' for encryption and decryption respectively.
;; - CBC mode is implemented straightforward, using a 0-padding to the full
;;   blocklength. The IV is appended to the ciphertext.
;; - OCB mode made the implementation of a pmac, based on AES, necessary, but
;;   the further details were straightforward. The IV is appended to the
;;   ciphertext. During decryption the created hash-value is checked.
;; - the function `aes-key-from-passwd' generates an AES key from an user input
;;   string (password).
;; - Further a facility is provided to generate random passwords, based on
;;   random user input like mousemovement, time and keyinput.
;; - The ciphertext is usually converted to a base-64 encoded string.

;; This implementation is not resistant against DPA attacks!

;; Known Bugs:
;; - Encrypted buffers are Auto-Saved unencrypted
;; - exiting emacs via C-x-c saves buffers unencrypted

;; [1] http://csrc.nist.gov/archive/aes/rijndael/Rijndael-ammended.pdf
;; [2] http://csrc.nist.gov/publications/fips/fips197/fips-197.pdf
;; [3] http://www.openssl.org/
;; [4] http://en.wikipedia.org/wiki/Block_cipher_modes_of_operation
;; [5] http://www.cs.ucdavis.edu/~rogaway/ocb/
;; [6] http://www.cs.ucdavis.edu/~rogaway/ocb/grant.htm

;;; Code:

;# xor

(defun aes-xor (x y)
  "Return X and Y bytewise xored.
X and Y and the return values are strings.
Y must not be shorter than X."
  (let* ((l (length x))
         (res (make-string l 0))
         (i 0))
    (while (< i l)
      (aset res i (logxor (aref x i) (aref y i)))
      (setq i (1+ i)))
    res))

(eval-when-compile
(defsubst aes-xor-4 (x y)
  "Return the 4 bytes long X and Y bytewise xored as string."
  (string (logxor (aref x 0) (aref y 0))
          (logxor (aref x 1) (aref y 1))
          (logxor (aref x 2) (aref y 2))
          (logxor (aref x 3) (aref y 3))))

(defmacro aes-xor-4-b (x y)
  "Return the 4 byte objects X and Y bytewise xored as new cons cell.
X and Y are objects of the form '((A . B) . (C . D))"
  `(cons (cons (logxor (car (car ,x)) (car (car ,y)))
               (logxor (cdr (car ,x)) (cdr (car ,y))))
         (cons (logxor (car (cdr ,x)) (car (cdr ,y)))
               (logxor (cdr (cdr ,x)) (cdr (cdr ,y))))))

(defsubst aes-xor-4-des-b (x y)
  "X and Y are bytewise xored destructively in X.
X and Y are objects of the form '((A . B) . (C . D))"
  (setcar (car x) (logxor (car (car x)) (car (car y))))
  (setcdr (car x) (logxor (cdr (car x)) (cdr (car y))))
  (setcar (cdr x) (logxor (car (cdr x)) (car (cdr y))))
  (setcdr (cdr x) (logxor (cdr (cdr x)) (cdr (cdr y)))))
)

;# Helpers

(defsubst aes-enlarge-to-multiple (v bs)
  "Enlarge string V to a multiple of BS and pad with Zeros."
  (concat v (make-string (mod (- (string-bytes v)) bs) 0)))

(defun aes-str-to-b (str)
  "Convert string STR to a list-representation.
The length of STR must be a multiple of 4.
The length of the resulting list has a quarter of the length of STR.
Elements 4*K to 4*K+3 of STR (named A, B, C and D in this order) are stored in
position K of the result as ((A . B) C . D)."
  (let (res
        (l (length str))
        (i 0))
    (while (< i l)
      (setq res (cons
                 (cons (cons (aref str i) (aref str (1+ i)))
                       (cons (aref str (+ i 2)) (aref str (+ i 3))))
                 res))
      (setq i (+ i 4)))
    (nreverse res)))
; (aes-str-to-b "0123456789abcdef")

(defun aes-list-expander (l &optional step len)
  "Create an expanded list of L.
The created list has as K-th element a sublist of L starting at
position K*STEP of L.
If LEN is non-nil, then the created list has length LEN. Otherwise it has a
length of L divided by STEP, rounded up to the next integer."
  (unless step (setq step 1))
  (if (consp l)
    (let* ((res (make-list (or len (ceiling (/ (length l) (+ 0.0 step)))) nil))
           (rp res))
      (while (and (setcar rp l)
                  (setq rp (cdr rp))
                  (setq l (nthcdr step l))))
      res)
    (error "Argument to `aes-list-expander' is not a cons: %s" l)))
; (aes-list-expander '() 23)

;# Multiplication

(eval-when-compile
(defsubst aes-mul-pre (a b)
  "Multiply the bytes A and B in GF2 and return their product."
  ;; For a description, see [1, Ch 2.1.2] or [2. Ch 4.2.1]
  (let ((p 0)
        (c 0))
    (while (< c 8)
      (if (= 1 (logand b 1))
          (setq p (logxor a p)))
      (if (prog1 (= #x80 (logand a #x80))
            (setq a (logand #xff (lsh a 1))))
          (setq a (logxor a #x1b)))
      (setq b (lsh b -1))
      (setq c (1+ c)))
    p)))

(let ((l (make-string 256 0))
      (mt (make-vector 256 0))
      (x 0)
      i res)
  (while (< x 256)
    (aset mt x (make-string 256 0))
    (setq x (1+ x)))
  (setq x 1)
  (while (< x 256)
    (setq i x)
    (while (< i 256)
      (setq res (aes-mul-pre i x))
      (if (= #x01 res) (progn (aset l x i) (aset l i x)))
      (aset (aref mt x) i res)
      (aset (aref mt i) x res)
      (setq i (1+ i)))
    (setq x (1+ x)))
  (defconst aes-mul-table mt
    "This variable contains the GF2 multiplication lookup table.")
  (defconst aes-inv-table l
    "This variable contains the GF2 inverting lookup table."))

;; The following 6 shortcuts are used during the time critical
;; functions `aes-SubShiftMixKeys' and `aes-InvSubShiftMixKeys'
(defconst aes-l2 (aref aes-mul-table #x02))
(defconst aes-l3 (aref aes-mul-table #x03))
(defconst aes-l9 (aref aes-mul-table #x09))
(defconst aes-le (aref aes-mul-table #x0e))
(defconst aes-lb (aref aes-mul-table #x0b))
(defconst aes-ld (aref aes-mul-table #x0d))

(defmacro aes-inv (x)
  "Calculate the inverse of X in GF2 by a table lookup in `aes-inv-table'."
  `(aref aes-inv-table ,x))

(defmacro aes-mul (x y)
  "Multiply x and y in GF2 by using the table lookup `aes-mul-table'."
  `(aref (aref aes-mul-table ,x) ,y))

;# SubBytes Transformation

(defconst aes-s-boxes-pre
  ;; For a description see [1, Ch 4.2.1] or [2, Ch 5.1.1]
  (let ((l1 (make-string 256 0))
        (l2 (make-string 256 0))
        (x 0))
    (while (< x 256)
      (let ((b (aes-inv x))
            (g 0)
            (c #x63)
            (i 0))
        (while (< i 8)
          (setq g (logxor (lsh (logand
                                (logxor
                                 (lsh (logxor b c) (- i))
                                 (lsh b (- (% (+ i 4) 8)))
                                 (lsh b (- (% (+ i 5) 8)))
                                 (lsh b (- (% (+ i 6) 8)))
                                 (lsh b (- (% (+ i 7) 8))))
                                1)
                               i)
                          g))
          (setq i (1+ i)))
        (aset l1 x g)
        (aset l2 g x))
      (setq x (1+ x)))
    (cons l1 l2))
  "This constant contains the lookup tables for S-boxes.
It is a pair where the car-value contains the S-box values used for encryption
and the cdr-value contains the S-box values used for decryption.
The S-boxes are stored as strings of length 256.")

(defconst aes-s-boxes-enc
  (car aes-s-boxes-pre)
  "Encryption S-Boxes")

(defconst aes-s-boxes-dec
  (cdr aes-s-boxes-pre)
  "Decryption S-Boxes")

(defsubst aes-SubBytes (state)
  "Apply the SubBytes transformation to each byte of the string STATE.
STATE may be of arbitrary length."
  ;; For a description of SubBytes see [1, Ch 4.2.1] or [2, Ch 5.1.1]
  (let ((l (length state))
        (i 0))
    (while (< i l)
      (aset state i (aref aes-s-boxes-enc (aref state i)))
      (setq i (1+ i)))))

(defun aes-InvSubBytes (state)
  "Apply the InvSubBytes transformation to each byte of the string STATE.
STATE may be of arbitrary length."
  ;; For a description of InvSubBytes see [1, Ch 4.2.1] or [2, Ch 5.3.2]
  (let ((l (length state))
        (i 0))
    (while (< i l)
      (aset state i (aref aes-s-boxes-dec (aref state i)))
      (setq i (1+ i)))))

(defsubst aes-SubWord (x)
  "Apply the SubBytes transformation to all 4 bytes of the string X."
  (aset x 0 (aref aes-s-boxes-enc (aref x 0)))
  (aset x 1 (aref aes-s-boxes-enc (aref x 1)))
  (aset x 2 (aref aes-s-boxes-enc (aref x 2)))
  (aset x 3 (aref aes-s-boxes-enc (aref x 3))))

(defsubst aes-SubWord-b (x)
  "Apply the SubBytes transformation to all 4 bytes of X.
X is of the form ((A . B) . (C . D))."
  (setcar (car x) (aref aes-s-boxes-enc (car (car x))))
  (setcdr (car x) (aref aes-s-boxes-enc (cdr (car x))))
  (setcar (cdr x) (aref aes-s-boxes-enc (car (cdr x))))
  (setcdr (cdr x) (aref aes-s-boxes-enc (cdr (cdr x)))))

;# ShiftRows Transformation

(defun aes-ShiftRows (state)
  "Apply the shift rows transformation destructively in STATE.
The length of STATE must be a multiple of 4 and larger than 12."
  ;; For a description of ShiftRows see [1, Ch 4.2.2] or [2, Ch 5.1.2]
  (let* ((border (- (length state) 4))
         (x (aref state 1))
         (c 1)
         (y (aref state 6))
         (z (aref state 11)))
    (while (< c border)
      (aset state c (aref state (+ c 4)))
      (setq c (+ c 4)))
    (aset state c x)
    (setq x (aref state 2))
    (setq c 2)
    (setq border (- border 4))
    (while (< c border)
      (aset state c (aref state (+ c 8)))
      (setq c (+ c 4)))
    (aset state c x)
    (aset state (+ c 4) y)
    (setq x (aref state 3))
    (setq y (aref state 7))
    (setq c 3)
    (setq border (- border 4))
    (while (< c border)
      (aset state c (aref state (+ c 12)))
      (setq c (+ c 4)))
    (aset state c x)
    (aset state (+ c 4) y)
    (aset state (+ c 8) z)))

(defun aes-InvShiftRows (state)
  "Apply the inverted shift rows transformation destructively in STATE.
The length of STATE must be a multiple of 4 and larger than 12."
  ;; For a description of InvShiftRows see [1, Ch 4.2.2] or [2, Ch 5.3.1]
  (let* ((Nb4 (length state))
         (c (- Nb4 3))
         (x (aref state c))
         (y (aref state (- Nb4 6)))
         (z (aref state (- Nb4 9))))
    (while (< 4 c)
      (aset state c (aref state (setq c (- c 4)))))
    (aset state 1 x)
    (setq x (aref state (setq c (- Nb4 2))))
    (while (< 8 c)
      (aset state c (aref state (- c 8)))
      (setq c (- c 4)))
    (aset state 6 x)
    (aset state 2 y)
    (setq x (aref state (setq c (- Nb4 1))))
    (setq y (aref state (- c 4)))
    (while (< 12 c)
      (aset state c (aref state (- c 12)))
      (setq c (- c 4)))
    (aset state 11 x)
    (aset state 7 y)
    (aset state 3 z)))
;(let ((s "0123456789abcdef")) (aes-ShiftRows s) s)

;# Combined Round Transformation

(defun aes-SubShiftMixKeys (state keys r)
  "Apply one round of the aes encryption to the string STATE.
KEYS is a string containing the expanded key schedule.
R is the number of the encryption round.
In one round the 4 transformations SubBytes, ShiftRows, MixColumns and
AddRoundKey are applied to STATE.
The length of STATE is a multiple of 4 and larger than 12.
The length of KEYS is at least (* (length STATE) (1+ R))."
  ;; For a description of MixColumns see [1, Ch 4.2.3] or [2, Ch 5.1.3]
  ;; For a description of AddRoundKey see [1, Ch 4.2.4] or [2, Ch 5.1.4]
  (let* ((copy (copy-sequence state))
         (x4 0)
         (Nb4 (length state))
         (xrNb4 (* r Nb4))
         s0 s1 s2 s3)
    (while (< x4 Nb4)
      (setq s0 (aref aes-s-boxes-enc (aref copy x4)))
      (setq s1 (aref aes-s-boxes-enc (aref copy (% (+ x4 1 4) Nb4))))
      (setq s2 (aref aes-s-boxes-enc (aref copy (% (+ x4 2 8) Nb4))))
      (setq s3 (aref aes-s-boxes-enc (aref copy (% (+ x4 3 12) Nb4))))
      (aset state x4 (logxor (aref aes-l2 s0) (aref aes-l3 s1) s2 s3
                             (aref keys xrNb4)))
      (aset state (1+ x4) (logxor s0 (aref aes-l2 s1) (aref aes-l3 s2) s3
                                  (aref keys (1+ xrNb4))))
      (aset state (+ 2 x4) (logxor s0 s1 (aref aes-l2 s2) (aref aes-l3 s3)
                                   (aref keys (+ 2 xrNb4))))
      (aset state (+ 3 x4) (logxor (aref aes-l3 s0) s1 s2 (aref aes-l2 s3)
                                   (aref keys (+ 3 xrNb4))))
      (setq x4 (+ 4 x4))
      (setq xrNb4 (+ 4 xrNb4)))))
; (byte-compile 'aes-SubShiftMixKeys)

(defun aes-SubShiftMixKeys-b (state keys)
  "See `aes-SubShiftMixKeys' for documentation."
  (let* ((copy (copy-sequence state))
         (x4 0)
         (Nb4 (length state))
         s0 s1 s2 s3 keyA)
    (while (< x4 Nb4)
      (setq s0 (aref aes-s-boxes-enc (aref copy x4)))
      (setq s1 (aref aes-s-boxes-enc (aref copy (% (+ x4 1 4) Nb4))))
      (setq s2 (aref aes-s-boxes-enc (aref copy (% (+ x4 2 8) Nb4))))
      (setq s3 (aref aes-s-boxes-enc (aref copy (% (+ x4 3 12) Nb4))))
      (setq keyA (car keys))
      (aset state x4 (logxor (aref aes-l2 s0) (aref aes-l3 s1) s2 s3
                             (car (car keyA))))
      (aset state (1+ x4) (logxor s0 (aref aes-l2 s1) (aref aes-l3 s2) s3
                                  (cdr (car keyA))))
      (aset state (+ 2 x4) (logxor s0 s1 (aref aes-l2 s2) (aref aes-l3 s3)
                                   (car (cdr keyA))))
      (aset state (+ 3 x4) (logxor (aref aes-l3 s0) s1 s2 (aref aes-l2 s3)
                                   (cdr (cdr keyA))))
      (setq keys (cdr keys))
      (setq x4 (+ x4 4)))))
; (byte-compile 'aes-SubShiftMixKeys-b)

;(let* ((plain (concat [#x00 #x11 #x22 #x33 #x44 #x55 #x66 #x77 #x88 #x99
;                            #xaa #xbb #xcc #xdd #xee #xff]))
;       (Nb (lsh (length plain) -2))
;       (key (concat [#x00 #x01 #x02 #x03 #x04 #x05 #x06 #x07 #x08 #x09
;                          #x0a #x0b #x0c #x0d #x0e #x0f]))
;       (Nk (lsh (length key) -2))
;       (Nr (+ (max Nb Nk) 6))
;       (keys (aes-KeyExpansion key Nb Nr))
;       )
;  (length keys))(/ 176 4)
;  (aes-SubShiftMixKeys plain 4 keys 1)
;  (prin1 (aes-str-to-b plain) 'insert)
;  )
;(((181 . 211) 146 . 36) ((38 . 200) 137 . 140) ((119 . 160) 68 . 5) ((4 . 64) 252 . 93))
;
;(let* ((Nb 4)
;       (plain (concat [#x00 #x11 #x22 #x33 #x44 #x55 #x66 #x77 #x88 #x99
;                            #xaa #xbb #xcc #xdd #xee #xff]))
;       (key (aes-str-to-b
;             (concat [#x00 #x01 #x02 #x03 #x04 #x05 #x06 #x07 #x08 #x09
;                           #x0a #x0b #x0c #x0d #x0e #x0f])))
;       (keys (aes-KeyExpansion-b key Nb))
;       )
;  (prin1
;   (benchmark-run-compiled
;    1000000
;    (aes-SubShiftMixKeys-b plain keys))
;   'insert))

;# Sub-Bytes Shift-Rows Mix-Columns Add Keys Inverse

(defun aes-InvSubShiftMixKeys (state keys r)
  "Apply the 4 inverted transformations to state."
  ;; For a description of InvMixColumns see [1, Ch 4.2.3] or [2, Ch 5.3.3]
  ;; For a description of InvAddRoundKey see [1, Ch 4.2.4] or [2, Ch 5.3.4]
  (let* ((copy (copy-sequence state))
         (x4 0)
         (Nb4 (length state))
         (xrNb4 (* r Nb4))
         s0 s1 s2 s3)
    (while (< x4 Nb4)
      (setq s0 (logxor (aref copy x4) (aref keys xrNb4)))
      (setq s1 (logxor (aref copy (1+ x4)) (aref keys (1+ xrNb4))))
      (setq s2 (logxor (aref copy (+ 2 x4)) (aref keys (+ 2 xrNb4))))
      (setq s3 (logxor (aref copy (+ 3 x4)) (aref keys (+ 3 xrNb4))))
      (aset state x4
            (aref aes-s-boxes-dec (logxor (aref aes-le s0) (aref aes-lb s1)
                                          (aref aes-ld s2) (aref aes-l9 s3))))
      (aset state (% (+ 1 4 x4) Nb4)
            (aref aes-s-boxes-dec (logxor (aref aes-l9 s0) (aref aes-le s1)
                                          (aref aes-lb s2) (aref aes-ld s3))))
      (aset state (% (+ 2 8 x4) Nb4)
            (aref aes-s-boxes-dec (logxor (aref aes-ld s0) (aref aes-l9 s1)
                                          (aref aes-le s2) (aref aes-lb s3))))
      (aset state (% (+ 3 12 x4) Nb4)
            (aref aes-s-boxes-dec (logxor (aref aes-lb s0) (aref aes-ld s1)
                                          (aref aes-l9 s2) (aref aes-le s3))))
      (setq x4 (+ x4 4))
      (setq xrNb4 (+ xrNb4 4)))))

;# Key Expansion

(defsubst aes-RotWord (x)
  "Rotate X by one byte.
Append the first byte to the end."
  (let ((te (aref x 0)))
    (aset x 0 (aref x 1)) (aset x 1 (aref x 2)) (aset x 2 (aref x 3))
    (aset x 3 te)))

(defsubst aes-RotWord-b (x)
  "Rotate X by one byte.
Append the first byte to the end."
  (let ((te (car (car x))))
    (setcar (car x) (cdr (car x)))
    (setcdr (car x) (car (cdr x)))
    (setcar (cdr x) (cdr (cdr x)))
    (setcdr (cdr x) te)))

(defun aes-KeyExpansion (key Nb &optional Nr)
  "Return a string, which contains the Key expansion of KEY."
  (let* ((Nk (lsh (length key) -2))
         (w (progn (unless Nr (setq Nr (+ (max Nb Nk) 6)))
                   (make-string (* 4 Nb (1+ Nr)) 0)))
         (i (lsh Nk 2))
         (rcon (concat (make-string 1 1) (make-string 3 0)))
         (Nk2 (lsh Nk 2)))
    (store-substring w 0 key)
    (while (< i (lsh (* Nb (1+ Nr)) 2))
      (let ((temp (substring w (- i 4) i)))
        (if (= 0 (% i Nk2))
            (progn (aes-RotWord temp)
                   (aes-SubWord temp)
                   (setq temp (aes-xor-4 temp rcon))
                   (aset rcon 0 (aes-mul (aref rcon 0) 2)))
          (if (and (< 6 Nk) (= (% (lsh i -2) Nk) 4))
              (aes-SubWord temp)))
        (store-substring
         w i (aes-xor-4 (substring w (- i Nk2) (+ 4 (- i Nk2))) temp)))
      (setq i (+ i 4)))
    w))
;; (prin1 (aes-str-to-b (aes-KeyExpansion "0123456789abcdef" 4)) 'insert)
;(byte-compile 'aes-KeyExpansion)
;(prin1
;(let ((x "0123456789abcdef"))
;(benchmark-run-compiled
; 100000
; (aes-KeyExpansion x 4)))
;'insert)
;(23.104 791 11.71399999999938)
;(23.54 806 12.244000000000044)

(defun aes-KeyExpansion-b (key Nb &optional Nr)
  "Return a vector, which contains the Key expansion of KEY."
  (let* ((Nk (length key))
         (w (reverse key))
         (i Nk)
         (rcon (cons (cons 1 0) (cons 0 0)))
         (Nk2 (lsh Nk 2))
         (border (* Nb (1+ (or Nr (+ (max Nb Nk) 6)))))
         (temp (cons (cons nil nil) (cons nil nil))))
    (while (< i border)
      (let ((f (car w)))
        (setcar (car temp) (car (car f)))
        (setcdr (car temp) (cdr (car f)))
        (setcar (cdr temp) (car (cdr f)))
        (setcdr (cdr temp) (cdr (cdr f)))
        (if (= 0 (% i Nk))
            (progn (aes-RotWord-b temp)
                   (aes-SubWord-b temp)
                   (aes-xor-4-des-b temp rcon)
                   (setcar (car rcon) (aes-mul (car (car rcon)) 2)))
          (if (and (< 6 Nk) (= (% i Nk) 4))
              (aes-SubWord-b temp)))
        (setq w (cons (aes-xor-4-b (nth 3 w) temp) w))
      (setq i (1+ i))))
    (nreverse w)))
;; (prin1 (aes-KeyExpansion-b (aes-str-to-b "0123456789abcdef") 4) 'insert)

;(byte-compile 'aes-KeyExpansion-b)
;(prin1 (symbol-function 'aes-KeyExpansion-b) 'insert)
;(prin1
;(let ((x (aes-str-to-b "0123456789abcdef")))
;  (benchmark-run-compiled
;      100000
;      (aes-KeyExpansion-b x 4)))
;'insert)
;(9.751 245 4.413999999999767)
;(10.280000000000001 281 5.1499999999997215)
;(10.265 280 5.131999999999728)
;(10.172 313 5.098999999999748)
;(10.062000000000001 290 4.552999999999795)

;# Add Round Key

(defsubst aes-AddRoundKey (state keys r Nb)
  "Add the keys specified  by R and NB of KEYS to STATE."
  (dotimes (i (lsh Nb 2))
    (aset state i (logxor (aref state i) (aref keys (+ (lsh (* r Nb) 2) i))))))

(defsubst aes-AddRoundKey-b (state keys)
  "Add the keys KEYS to STATE."
  (let ((Nb4 (length state))
        (i 0))
    (while (< i Nb4)
      (let ((keysA (car keys)))
        (aset state i (logxor (aref state i) (car (car keysA))))
        (aset state (1+ i) (logxor (aref state (1+ i)) (cdr (car keysA))))
        (aset state (+ 2 i) (logxor (aref state (+ 2 i)) (car (cdr keysA))))
        (aset state (+ 3 i) (logxor (aref state (+ 3 i)) (cdr (cdr keysA))))
        (setq keysA (car (setq keys (cdr keys))))
        (aset state (+ 4 i) (logxor (aref state (+ 4 i)) (car (car keysA))))
        (aset state (+ 5 i) (logxor (aref state (+ 5 i)) (cdr (car keysA))))
        (aset state (+ 6 i) (logxor (aref state (+ 6 i)) (car (cdr keysA))))
        (aset state (+ 7 i) (logxor (aref state (+ 7 i)) (cdr (cdr keysA))))
        (setq keys (cdr keys)))
      (setq i (+ 8 i)))))
; (byte-compile 'aes-AddRoundKey-b)

;# Cipher

(defun aes-Cipher (input keys Nb &optional Nr)
  "Perform the AES encryption.
Assumes that input and keys are of the correct length."
  (let* ((Nk (- (/ (lsh (length keys) -2) Nb) 7))
         (state (make-string (lsh Nb 2) 0))
         (r 1))
    (unless Nr (setq Nr (+ (max Nb Nk) 6)))
    (store-substring state 0 input)
    (aes-AddRoundKey state keys 0 Nb)
    (while (< r Nr)
      (aes-SubShiftMixKeys state keys r)
      (setq r (1+ r)))
    (aes-SubBytes state)
    (aes-ShiftRows state)
    (aes-AddRoundKey state keys Nr Nb)
    state))

(defun aes-Cipher-b (input keys Nb &optional Nr)
  "Perform the AES encryption.
Assumes that input and keys are of the correct length."
  (let* ((Nk (- (/ (length keys) Nb) 7))
         (state (make-string (lsh Nb 2) 0))
         (r 1))
    (unless Nr (setq Nr (+ (max Nb Nk) 6)))
    (store-substring state 0 input)
    (aes-AddRoundKey-b state keys)
    (while (< r Nr)
      (aes-SubShiftMixKeys-b state (setq keys (nthcdr Nb keys)))
      (setq r (1+ r)))
    (aes-SubBytes state)
    (aes-ShiftRows state)
    (aes-AddRoundKey-b state (nthcdr 4 keys))
    state))
; (byte-compile 'aes-Cipher-b)

;(let* ((Nb 4)
;       (plain (concat [#x00 #x11 #x22 #x33 #x44 #x55 #x66 #x77 #x88 #x99
;                            #xaa #xbb #xcc #xdd #xee #xff]))
;       (key (concat [#x00 #x01 #x02 #x03 #x04 #x05 #x06 #x07 #x08 #x09
;                          #x0a #x0b #x0c #x0d #x0e #x0f]))
;       (keys (aes-KeyExpansion key Nb))
;       )
;  (prin1
;   (benchmark-run-compiled
;    100000
;    (aes-Cipher plain keys Nb))
;   'insert)
;;  (prin1 (aes-str-to-b (aes-Cipher plain keys Nb)) 'insert)
;  )
;(9.547 104 1.4649999999999994)
;
;(let* ((Nb 4)
;       (plain (concat [#x00 #x11 #x22 #x33 #x44 #x55 #x66 #x77 #x88 #x99
;                            #xaa #xbb #xcc #xdd #xee #xff]))
;       (key (aes-str-to-b
;             (concat [#x00 #x01 #x02 #x03 #x04 #x05 #x06 #x07 #x08 #x09
;                           #x0a #x0b #x0c #x0d #x0e #x0f])))
;       (keys (aes-KeyExpansion-b key Nb))
;       )
;  (prin1
;   (benchmark-run-compiled
;    100000
;       (aes-Cipher-b plain keys Nb))
;   'insert)
;  )
;(8.876000000000001 104 1.4230000000000034)

;# Inv Cipher

(defun aes-InvCipher (input keys Nb &optional Nr)
  "Perform the AES decryption."
  (let* ((Nk (- (/ (lsh (length keys) -2) Nb) 7))
         (state (make-string (lsh Nb 2) 0))
         (r (progn (unless Nr (setq Nr (+ (max Nb Nk) 6)))
                   (- Nr 1))))
    (store-substring state 0 input)
    (aes-AddRoundKey state keys Nr Nb)
    (aes-InvShiftRows state)
    (aes-InvSubBytes state)
    (while (< 0 r)
      (aes-InvSubShiftMixKeys state keys r)
      (setq r (- r 1)))
    (aes-AddRoundKey state keys 0 Nb)
    state))

;# cbc implementation

(defun aes-cbc-encrypt (input iv keys Nb)
  "Encrypt INPUT by the CBC method using AES for encryption.
Use IV as initialization vector, KEYS as the key expansion and Nb as
blocksize."
  (let* ((Nk (- (/ (lsh (length keys) -2) Nb) 7))
         (Nr (+ (max Nb Nk) 6))
         (blocksize (lsh Nb 2))
         (res (aes-enlarge-to-multiple input blocksize))
         (blocknumber (/ (string-bytes res) blocksize))
         (pointer 0))
    (dotimes (b blocknumber)
      (let ((temp (aes-Cipher-b
                   (aes-xor iv (substring res (* b blocksize)
                                          (* (1+ b) blocksize)))
                   keys Nb)))
        (store-substring res (* b blocksize) temp)
        (setq iv temp)))
    res))

(defun aes-cbc-decrypt (input iv keys Nb)
  "Decrypt INPUT by the CBC method using AES for decryption.
Use IV as initialization vector, KEYS as the key expansion and Nb as
blocksize."
  (let* ((Nk (- (/ (lsh (length keys) -2) Nb) 7))
         (Nr (+ (max Nb Nk) 6))
         (blocksize (lsh Nb 2))
         (res (aes-enlarge-to-multiple input blocksize))
         (blocknumber (/ (string-bytes res) blocksize))
         (pointer 0))
    (dotimes (b blocknumber)
      (let ((temp (substring res (* b blocksize) (* (1+ b) blocksize))))
        (store-substring res (* b blocksize)
                         (aes-xor iv (aes-InvCipher temp keys Nb)))
        (setq iv temp)))
      res))

;# ocb 2.0

(defun aes-128-double (x)
  "Double X in 128 bit field."
  (let ((c (lsh (aref x 0) -7))
        (res (make-string 16 0)))
    (dotimes (i 15)
      (aset res i (logand #xff (logxor (lsh (aref x i) 1)
                                       (lsh (aref x (+ i 1)) -7)))))
    (aset res 15 (logand #xff (logxor (lsh (aref x 15) 1) (* c #x87))))
    res))

(defsubst aes-128-triple (x)
  "Triple X in 128 bit field."
  (aes-xor (aes-128-double x) x))

(defun aes-num2str (x n)
  "Calculate the n-bit representation of x."
  (let ((res (make-string n 0))
        (offset (- n 1)))
    (while (< 0 x)
      (aset res offset (logand x #xff))
      (setq x (lsh x -8))
      (setq offset (- offset 1)))
    res))

(defun aes-pmac (header keys Nb)
  "Calculate aes-PMAC of header using keys."
  (let* ((l (length header))
         (blocksize (lsh Nb 2))
         (whole-blocks (/ l blocksize))
         (total-blocks (max 1 (+ whole-blocks (if (= 0 (% l blocksize)) 0 1))))
         (b (if (= whole-blocks total-blocks) blocksize (% l blocksize)))
         (D (aes-128-triple
             (aes-128-triple (aes-Cipher (make-string blocksize 0) keys Nb))))
         (checksum (make-string blocksize 0))
         )
    (dotimes (i (- total-blocks 1))
      (setq D (aes-128-double D))
      (setq checksum
            (aes-xor checksum
                     (aes-Cipher (aes-xor D (substring header (* i blocksize)
                                                       (* (+ i 1) blocksize)))
                                 keys Nb))))
    (setq D  (aes-128-double D))
    (if (= b blocksize)
        (progn (setq D (aes-128-triple D))
               (setq checksum
                     (aes-xor checksum
                              (substring header
                                         (* blocksize (- total-blocks 1))))))
      (setq D (aes-128-triple (aes-128-triple D)))
      (setq checksum
            (aes-xor checksum
                     (concat (substring header
                                        (* blocksize (- total-blocks 1)))
                             (char-to-string #x80)
                             (make-string (- blocksize
                                             (+ 1 b)) 0)))))
    (aes-Cipher (aes-xor D checksum) keys Nb)))

(defun aes-pmac-b (header keys Nb)
  "Calculate aes-PMAC of header using keys."
  (let* ((l (length header))
         (blocksize (lsh Nb 2))
         (whole-blocks (/ l blocksize))
         (total-blocks (max 1 (+ whole-blocks (if (= 0 (% l blocksize)) 0 1))))
         (b (if (= whole-blocks total-blocks) blocksize (% l blocksize)))
         (D (aes-128-triple
             (aes-128-triple (aes-Cipher-b (make-string blocksize 0) keys Nb))))
         (checksum (make-string blocksize 0))
         )
    (dotimes (i (- total-blocks 1))
      (setq D (aes-128-double D))
      (setq checksum
            (aes-xor checksum
                     (aes-Cipher-b (aes-xor D (substring header (* i blocksize)
                                                         (* (+ i 1) blocksize)))
                                   keys Nb))))
    (setq D  (aes-128-double D))
    (if (= b blocksize)
        (progn (setq D (aes-128-triple D))
               (setq checksum
                     (aes-xor checksum
                              (substring header
                                         (* blocksize (- total-blocks 1))))))
      (setq D (aes-128-triple (aes-128-triple D)))
      (setq checksum
            (aes-xor checksum
                     (concat (substring header
                                        (* blocksize (- total-blocks 1)))
                             (char-to-string #x80)
                             (make-string (- blocksize
                                             (+ 1 b)) 0)))))
    (aes-Cipher-b (aes-xor D checksum) keys Nb)))

(defun aes-ocb-encrypt (header input iv keys Nb)
  "OCB encrypt input and calculate auth of header and input."
  (let* ((D (aes-Cipher-b iv keys Nb))
         (C "")
         (T "")
         (checksum (make-string (lsh Nb 2) 0))
         (l (length input))
         (blocksize (lsh Nb 2))
         (whole-blocks (/ l blocksize))
         (total-blocks (max 1 (+ whole-blocks (if (= 0 (% l blocksize)) 0 1))))
         (b (if (= whole-blocks total-blocks) blocksize (% l blocksize)))
         )
;;    (list whole-blocks last-bytes total-blocks)))
    (dotimes (i (- total-blocks 1))
      (setq D (aes-128-double D))
      (setq checksum (aes-xor checksum (substring input (* i blocksize)
                                                  (* (+ i 1) blocksize))))
      (setq C (concat C (aes-xor D (aes-Cipher-b
                                    (aes-xor D (substring
                                                input (* i blocksize)
                                                (* (+ i 1) blocksize)))
                                    keys Nb)))))
    (setq D (aes-128-double D))
    (let ((pad (aes-Cipher-b (aes-xor D (aes-num2str (* 8 b) blocksize))
                             keys
                             Nb))
          (Mm (substring input (* blocksize (- total-blocks 1)))))
      (setq C (concat C (aes-xor Mm (substring pad 0 b))))
      (setq checksum (aes-xor checksum (concat Mm (substring pad b)))))
    (setq D (aes-128-triple D))
    (setq T (aes-Cipher-b (aes-xor checksum D) keys Nb))
    (if (< 0 (length header)) (setq T (aes-xor T (aes-pmac-b header keys Nb))))
    (cons C T)))

(defun aes-ocb-decrypt (header input tag iv keys Nb)
  "OCB decrypt input and verify authentication tag of header and input."
  (let* ((D (aes-Cipher iv keys Nb))
         (M "")
         (l (length input))
         (blocksize (lsh Nb 2))
         (checksum (make-string blocksize 0))
         (whole-blocks (/ l blocksize))
         (total-blocks (max 1 (+ whole-blocks (if (= 0 (% l blocksize)) 0 1))))
         (b (if (= whole-blocks total-blocks) blocksize (% l blocksize)))
         )
    (dotimes (i (- total-blocks 1))
      (setq D (aes-128-double D))
      (let ((Mi (aes-xor D (aes-InvCipher
                            (aes-xor D (substring input (* i blocksize)
                                                  (* (+ i 1) blocksize)))
                            keys Nb))))
        (setq M (concat M Mi))
        (setq checksum (aes-xor checksum Mi))))
    (setq D (aes-128-double D))
    (let* ((pad (aes-Cipher (aes-xor (aes-num2str (* 8 b) blocksize)
                                     D)
                            keys
                            Nb))
           (Mm (aes-xor (substring
                         input (* blocksize (- total-blocks 1)))
                        (substring pad 0 b))))
      (setq M (concat M Mm))
      (setq checksum
            (aes-xor checksum
                     (concat Mm (substring pad b)))))
    (setq D (aes-128-triple D))
    (let ((T (aes-Cipher (aes-xor D checksum) keys Nb)))
      (if (< 0 (length header))
          (setq T (aes-xor T (aes-pmac header keys Nb))))
      (if (equal tag
                 (substring T 0 (length tag)))
          (cons t M)
        (cons nil "")))))

;# Password handling and key generation from passwords

(defgroup aes nil
  "Advanced Encryption Standard implementation"
  :group 'applications)

(defcustom aes-always-ask-for-passwords t
  "Always ask for passwords, if non-nil.
Set this to nil, if you are risky.
If this variable is set to a non-nil value, then no passwords are stored in
aes-plaintext-passwords."
  :type 'boolean
  :group 'aes)

(defcustom aes-enable-plaintext-password-storage nil
  "Store passwords in emacs-memory in plaintext, if non-nil.
Set this to a non-nil value, if you are risky.
Enabling this feature allows someone to read the passwords in plaintext by
accessing the variable aes-plaintext-passwords.
If changing the value from non-nil to nil, then the passwords stored in
aes-plaintext-passwords are not deleted automatically."
  :type 'boolean
  :group 'aes)

(defvar aes-plaintext-passwords ()
  "Association list of plaintext passwords.
Warning: passwords are stored in plaintext and can be read by anyone with
access to the current emacs session.")
;; (setq aes-plaintext-passwords)

(defun aes-clear-plaintext-keys ()
  "Remove all stored passwords."
  (interactive)
  (setq aes-plaintext-passwords))

(defvar aes-idle-timer-value nil
  "Reference to idle timer.")

(defun aes-idle-clear-plaintext-keys ()
  "Remove all stored passwords."
  (setq aes-plaintext-passwords)
  (setq aes-idle-timer-value nil)
  (with-current-buffer "*Messages*"
    (erase-buffer))
  (message "AES Passwords cleared."))

(defcustom aes-delete-passwords-after-idle 1
  "Delete the stored passwords after the given time.
This is disabled, if the value is 0. Otherwise the number is
interpreted as seconds for emacs to be idle before the deletion
happens."
  :type 'integer
  :group 'aes)

(defvar aes-path-passwd-hook ()
  "Hook for testing paths.
Functions, appended to this hook, get one argument: a path of a file to be
en- or decrypted.
According to the path the function should return a string, providing
information about the location, or NIL otherwise.
Using this method it is possible to store the same password, used for multiple
files.
See gtd-mode.el for an example.")

(defun aes-exec-passws-hooks (path)
  "Run the functions in the hook aes-path-passwd-hook.
Return a string resulting from one of the hook functions or NIL otherwise."
  (let ((res (run-hook-with-args-until-success 'aes-path-passwd-hook path)))
    res))

(defcustom aes-verify-passwords t
  "Ask for passwords for encryption twice, if non-nil."
  :type 'boolean
  :group 'aes)

(defun aes-key-from-passwd (Nk usage &optional type-or-file)
  "Return a key, generated from a password.
USAGE must be a string either \"encryption\" or \"decryption\" denoting the
usage of the password.
If aes-use-plaintext-keys is nil and aes-disable-global-plaintext-keys is
non-nil, then use aes-plaintext-passwords for storing and reading passwords.
Query the password from the user if it is not available via
aes-plaintext-passwords."
  (if (not (member usage '("encryption" "decryption")))
      (error "Wrong argument in aes-key-from-passwd: \"%S\"" usage))
  (unless type-or-file (setq type-or-file ""))
  (let* ((pre-passwd
          (if (and (not aes-always-ask-for-passwords)
                   aes-enable-plaintext-password-storage
                   (assoc type-or-file aes-plaintext-passwords))
              (cdr (assoc type-or-file aes-plaintext-passwords))
            (let ((p ""))
              (while (equal p "")
                (setq p (read-passwd
                         (concat usage " Password for " type-or-file ": ")
                         (and (equal "encryption" usage)
                              aes-verify-passwords))))
              (if (and (not aes-always-ask-for-passwords)
                       aes-enable-plaintext-password-storage
                       (not (get-buffer type-or-file))
                       (not (equal "string" type-or-file)))
                  (progn
                    (setq aes-plaintext-passwords
                          (cons (cons type-or-file p) aes-plaintext-passwords))
                    ;; reset idle timer
                    (if aes-idle-timer-value
                        (progn (cancel-timer aes-idle-timer-value)
                               (setq aes-idle-timer-value nil)))
                    ;; set new idle timer
                    (if (< 0 aes-delete-passwords-after-idle)
                        (setq aes-idle-timer-value
                              (run-with-idle-timer
                               aes-delete-passwords-after-idle
                               nil
                               'aes-idle-clear-plaintext-keys)))))
              p)))
         (passwd (aes-enlarge-to-multiple pre-passwd (lsh Nk 2)))
         (passwdkeys
          (aes-KeyExpansion-b
           (aes-str-to-b (substring passwd 0 (lsh Nk 2))) Nk))
         (passwdiv (make-string (lsh Nk 2) 0))
         (passwdcbc (aes-cbc-encrypt passwd passwdiv passwdkeys Nk))
         (key (substring passwdcbc (- (lsh Nk 2)))))
    key))

(defcustom aes-password-char-groups
  '((?a t "abcdefghjkmnopqrstuvwxyz") ; downcase letters, i and l excluded
    (?A t "ABCDEFGHJKLMNPQRSTUVWXYZ") ; upcase letters, I and O excluded
    (?5 t "23456789")                 ; numbers, 0 and 1 excluded
    (?0 t "0OilI1")                   ; characters difficult to distinguish
    (?. nil ",.!?;:_()[]{}<>")        ; punctuation and brackets
    (?+ nil "-+*/=")                  ; calculation
    (?% nil "|^~#$%&'"))              ; others
  "Groups of characters for password generation.
The first entry in each list is a character, which can be used in the
argument TYP of aes-generate-password to refer to this password
group. The second entry denotes the default value of the application
of this character group. The third entry denotes the characters in
this group used for password generation."
  :group 'aes
  :type '(repeat (list character (choice (const :tag "active" t)
                                         (const :tag "inactive" nil))
                       string)))
;; (setq aes-password-char-groups ())
;; (customize-group 'aes)

(defun aes-fisher-yates-shuffle-string (s)
  (let ((i (1- (length s))))
    (while (< 0 i)
      (let ((j (random (1+ i)))
            (temp (aref s i)))
        (aset s i (aref s j))
        (aset s j temp))
      (setq i (1- i))))
  s)
;, (aes-fisher-yates-shuffle-string "abcdefghijklmnopqrestuvwxyz")

(defcustom aes-user-interaction-entropy t
  "Query User for Entropy if non-nil.
Otherwise use emacs internal pseudo random number generator."
  :type 'boolean
  :group 'aes)

(defun aes-provide-entropy (len &optional localmax)
  "Return an entropy string of LEN characters.
Read entropy from keyboard and mouse.
It is assumed that a keyboard event provides 8 bit of entropy and a mouse
event 8 bits of entropy."
  (unless localmax (setq localmax 256))
  (if (not aes-user-interaction-entropy)
      (let ((res (make-string len 0)))
        (dotimes (i len) (aset res i (random localmax)))
        res)
    (let* ((ctr (if (= (logand #xf len) 0)
                    len
                  (logand (lognot #xf) (+ len 16))))
           (read-bits 0)
           (input "")
           (res (make-string len 0))
           (res1 ""))
      (while (< (/ read-bits 8) ctr)
        (let ((eve (track-mouse (read-event (format "Provide Entropy by pressing keys and clicking mouse at random locations or moving the mouse. (%2.2f%%): " (* 100 (/ read-bits 8.0 ctr)))))))
          (setq read-bits (+ read-bits (if (listp eve)
                                           (+ 1 ; eventtype
                                              1 ; window
                                              5 ; position
                                              1 ; time
                                              ) ; Mouse
                                         (setq input (concat input (format "%S" (current-time))))
                                         (+ 4    ; character
                                            4    ; time
                                            )))) ; Key
          (setq input (concat input (format "%S" eve)))))
      (while (< (length res1) len)
        (let* ((iv (let ((res (make-string 16 0)))
                     (dotimes (i 16) (aset res i (random 256)))
                     res))
               (key (let ((res (make-string 16 0)))
                      (dotimes (i 16) (aset res i (random 256)))
                      (aes-str-to-b res)))
               (i 0)
               (res2 (aes-cbc-encrypt input iv (aes-KeyExpansion-b key 4) 4)))
          (while (< i (length res2))
            (if (< (aref res2 i) localmax)
                (setq i (+ i 1))
              (setq res2 (concat (substring res2 0 i)
                                 (substring res2 (+ i 1))))))
          (setq res1 (concat res1 res2)))
        (if (< (length res1) len) (aes-fisher-yates-shuffle-string input)))
      (dotimes (i len)
        (let ((this (aref res1 (truncate (* i (/ (length res1) 1.0 len))))))
          (aset res i
                this)))
      res)))
; (aes-provide-entropy 10)

(defun aes-generate-password (length &optional typ)
  "Return a password of length LENGTH.
TYP is a string consisting only of a subset of the characters defined in
the car values of aes-password-char-groups."
  (let* ((cs (mapcar 'car aes-password-char-groups))
         (case-fold-search nil)
         (chars
          (let ((res ""))
            (dolist (c cs)
              (setq
               res
               (concat res
                       (if typ
                           (and (string-match (regexp-quote (char-to-string c)) typ)
                                (elt (assoc c aes-password-char-groups) 2))
                         (or (and (cadr (assoc c aes-password-char-groups))
                                  (elt (assoc c aes-password-char-groups) 2))
                             "")))))
            res))
         (clen (length chars))
         (thismax (* clen (/ 256 clen)))
         (res (aes-provide-entropy length thismax)))
    (dotimes (i (length res))
      (aset res i (aref chars (% (aref res i) clen))))
    res))

(defun aes-insert-password (length)
  "Insert a password of the specified length LENGTH at point."
  (interactive "NLength of password: ")
  (insert (aes-generate-password length)))

;# buffer and string en-/decryption

(defun aes-toggle-representation (s)
  "Toggles string S between unibyte and multibyte.
Return a new string containing the other representation."
  (let ((mb (multibyte-string-p s)))
    (with-temp-buffer
      (if (not mb) (set-buffer-multibyte nil))
      (insert s)
      (set-buffer-multibyte (not mb))
      (buffer-substring-no-properties (point-min) (point-max)))))

(defcustom aes-discard-undo-after-encryption t
  "Delete undo information after encryption, if non-nil."
  :type 'boolean
  :group 'aes)

(defcustom aes-ocb-max-default-length 20000
  "Default maximal length for using OCB for encryption.
If a buffer or string is longer, then use CBC."
  :type 'integer
  :group 'aes)

(defun aes-encrypt-buffer-or-string (bos &optional type Nk Nb non-b64)
  "Encrypt buffer or string bos by the AES-method.
If BOS is a string matching the name of a buffer, then this buffer is used.
Use method TYPE. (OCB or CBC)
Use Nk as keysize (defaults to 4).
Use Nb as blocksite (defaults to 4 and is always 4 for OCB).
Use base64-encoding if non-b64 is NIL, and binary representation otherwise
\(defaults to NIL).
Use a weak-random initialization vector.
Get the key for encryption by the function aes-key-from-passwd."
  (let* ((bs (or (get-buffer bos) (bufferp bos))) ; t: buffer nil: string
         (length (if bs (with-current-buffer bs (point-max)) (length bos))))
    (unless type (setq type (if (< length aes-ocb-max-default-length)
                                "OCB"
                              "CBC"))) ;; use OCB or CBC dependend on length
    (unless Nb (setq Nb 4)) ;; default blocksize of 16 byte / 128 bit
    (unless Nk (setq Nk 4)) ;; default keysize of 16 byte / 128 bit
    (if (and (equal type "OCB") (not (= Nb 4)))
        (setq Nb 4)) ;; blocksize for OCB is 16 byte / 128 bit
    (if (not (member type '("OCB" "CBC")))
        (message "Wrong type.")
      (let* ((passtype (or (if bs (aes-exec-passws-hooks
                                   (buffer-file-name bs)))
                           (if bs (if (bufferp bos) (buffer-name bos) bos)
                             "string")))
             (Nr (+ (max Nb Nk) 6))
             (key (aes-str-to-b (aes-key-from-passwd Nk "encryption" passtype)))
             (keys (aes-KeyExpansion-b key Nb))
             (iv (let ((x (make-string (lsh Nb 2) 0)))
                   (dotimes (i (lsh Nb 2)) (aset x i (random 256)))
                   x))
             (ums (if bs (with-current-buffer bos
                           (cons (if enable-multibyte-characters
                                     (progn (set-buffer-multibyte nil) "M")
                                   "U")
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))
                    (if (multibyte-string-p bos)
                        (cons "M" (aes-toggle-representation bos))
                      (cons "U" bos))))
             (header (format "aes-encrypted V 1.2-%s-%s-%d-%d-%s\n"
                             type (if non-b64 "N" "B") Nb Nk (car ums)))
             (l (length (cdr ums)))
             (plain (cond ((equal type "OCB") (cdr ums))
                          ((equal type "CBC")
                           (concat (number-to-string l) "\n" (cdr ums)))))
             (enc (cond ((equal type "OCB")
                         (let ((res (aes-ocb-encrypt header plain iv keys Nb)))
                           (concat iv (cdr res) (car res))))
                        ((equal type "CBC")
                         (concat iv (aes-cbc-encrypt plain iv keys Nb)))))
             (res1 (if non-b64 enc (base64-encode-string enc)))
             (res (concat header res1)))
        (if bs (with-current-buffer bos
                 (erase-buffer)
                 (insert res)
                 (if aes-discard-undo-after-encryption
                     (setq buffer-undo-list))
                 t)
          res)))))

;; (aes-encrypt-buffer-or-string "address.xml" "CBC")

(defun aes-decrypt-buffer-or-string (bos)
  "Decrypt BOS V 1.2.
BOS is a buffer, a buffer name or a string.
If BOS is a string matching the name of a buffer, then this buffer is used.
Get the key for encryption by the function aes-key-from-passwd."
  (let* ((bs (or (bufferp bos) (get-buffer bos))) ; t: buffer nil: string
         (sp (if bs (with-current-buffer bos
                      (buffer-substring-no-properties (point-min) (point-max)))
               bos)))
    (if (not (string-match
              (concat "aes-encrypted V 1.2-\\(CBC\\|OCB\\)-"
                      "\\([BN]\\)-\\([0-9]+\\)-\\([0-9]+\\)-\\([MU]\\)\n") sp))
        (message (concat "buffer or string '" bos
                         "' is not properly encrypted."))
      (let* ((type (match-string 1 sp))
             (b64 (equal "B" (match-string 2 sp)))
             (Nb (string-to-number (match-string 3 sp)))
             (blocksize (lsh Nb 2))
             (Nk (string-to-number (match-string 4 sp)))
             (Nr (+ (max Nk Nb) 6))
             (um (match-string 5 sp))
             (header (match-string 0 sp))
             (res1 (substring sp (match-end 0)))
             (res2 (if b64 (base64-decode-string res1) res1))
             (iv (substring res2 0 blocksize))
             (enc-offset (cond ((equal type "CBC") blocksize)
                               ((equal type "OCB") (lsh blocksize 1))))
             (tag (substring res2 blocksize enc-offset))
             (enc (substring res2 enc-offset))
             (passtype (or (if bs (aes-exec-passws-hooks (buffer-file-name bos)))
                           (if bs (if (bufferp bos) (buffer-name bos) bos)
                             "string")))
             (key (aes-key-from-passwd Nk "decryption" passtype))
             (keys (aes-KeyExpansion key Nb))
             (res1 (cond ((equal type "CBC") (aes-cbc-decrypt enc iv keys Nb))
                         ((equal type "OCB")
                          (aes-ocb-decrypt header enc tag iv keys Nb)))))
        (if (or (and (equal type "CBC")
                     (not (string-match "\\`\\([0-9]+\\)\n" res1)))
                (and (equal type "OCB") (not (car res1))))
            (message (concat "buffer or string '"
                             (if (bufferp bos) (buffer-name bos) bos)
                             "' could not be decrypted."))
          (let* ((len (and (equal type "CBC")
                         (string-to-number (match-string 1 res1))))
                 (res (cond ((equal type "CBC")
                             (substring res1 (match-end 0)
                                        (+ (match-end 0) len)))
                            ((equal type "OCB") (cdr res1)))))
            (if bs (with-current-buffer bos
                     (erase-buffer) (set-buffer-multibyte nil)
                     (insert res) (set-buffer-multibyte um)
                     (setq buffer-file-coding-system
                           (car (find-coding-systems-region
                                 (point-min) (point-max))))
                     t)
              (if um (aes-toggle-representation res) res))))))))

(defun aes-encrypt-and-dont-save ()
  "Encrypt and dont save current buffer.
Return NIL."
  (goto-char (point-min))
  (if (not (looking-at "aes-encrypted V [0-9]+.[0-9]+-.+\n"))
      (progn
        (aes-encrypt-buffer-or-string (current-buffer))
        (goto-char (point-min))
        nil)))

(defun aes-encrypt-current-buffer ()
  "Encrypt current buffer."
  (interactive)
  (aes-encrypt-buffer-or-string (current-buffer)))

(defun aes-decrypt-current-buffer ()
  "Decrypt current buffer."
  (interactive)
  (aes-decrypt-buffer-or-string (current-buffer)))

(defun aes-is-encrypted ()
  "Check if current buffer is aes-encrypted."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "\\=aes-encrypted V [0-9]+.[0-9]+-.+\n" nil t)
        t
      nil)))

(defun aes-toggle-encryption ()
  "Encrypt or decrypt current buffer. Set according saving hook.
Preserve modification status of buffer during decryption."
  (interactive)
  (goto-char (point-min))
  (if (looking-at "aes-encrypted V [0-9]+.[0-9]+-.+\n")
      (let ((mod-flag (buffer-modified-p)))
        (aes-decrypt-buffer-or-string (current-buffer))
        (set-buffer-modified-p mod-flag)
        (add-hook (if (<= emacs-major-version 21)
                      'local-write-file-hooks
                    'write-file-functions)
                  'aes-encrypt-and-dont-save nil t))
    (aes-encrypt-buffer-or-string (current-buffer)))
  (goto-char (point-min)))

(defun aes-remove-encryption-hook ()
  "Remove saving-hook from current buffer.
This allows saving a previously encrypted buffer in plaintext."
  (interactive)
  (remove-hook (if (<= emacs-major-version 21)
                   'local-write-file-hooks
                 'write-file-functions)
               'aes-encrypt-and-dont-save t)
  (message "Encryption Hook removed."))

(defun aes-auto-decrypt (&rest x)
  "Function for auto decryption used in format-alist.
WARNING: not compliant to format-alist in the sense that the function
decrypts the whole file and not just the indicated region."
  (goto-char (point-min))
  (if (looking-at "aes-encrypted V [0-9]+.[0-9]+-.+\n")
      (let ((mod-flag (buffer-modified-p)))
        (aes-decrypt-buffer-or-string (current-buffer))
        (set-buffer-modified-p mod-flag)
        (if (<= emacs-major-version 21)
            (add-hook 'local-write-file-hooks 'aes-encrypt-and-dont-save nil t)
          (add-hook 'write-file-functions 'aes-encrypt-and-dont-save nil t))
        ))
  (goto-char (point-min))
  (point-max))

(defun aes-enable-auto-decryption ()
  "Enable auto decryption via format-alist."
  (if (assoc 'aes format-alist)
      (setq format-alist (assq-delete-all 'aes format-alist)))
  (setq format-alist
        (cons (list 'aes
                    "AES-encrypted format"
                    "aes-encrypted V [0-9]+.[0-9]+-.+\n"
                    'aes-auto-decrypt
                    nil
                    t
                    nil)
              format-alist)))
;; (aes-enable-auto-decryption)

;# Provide

(provide 'aes)

;# Footer
;; Local Variables:
;; mode: outline-minor
;; comment-column:0
;; outline-regexp: ";#+ "
;; End:

;;; aes.el ends here
