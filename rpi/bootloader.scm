;;; rpi/bootloader.scm — the bootloader record for a board that has none.
;;;
;;; <operating-system> REQUIRES a bootloader, and every bootloader Guix ships
;;; installs something: u-boot-bootloader inherits extlinux-bootloader, so
;;; `guix system reconfigure' writes /boot/extlinux/extlinux.conf into the root
;;; file system and the boot chain gains a second configuration file that the
;;; firmware never reads. On these boards the firmware loads the kernel itself
;;; from the FAT boot partition, and the only writer of that partition is
;;; rpi-boot-populate (see docs/boot-chain.org).
;;;
;;; %direct-kernel-bootloader is the record for that situation:
;;;
;;;   - no package: nothing is installed, so there is no tool to reference;
;;;   - no installer: reconfigure/init performs no bootloader step at all,
;;;     which is what "the firmware owns the boot chain" means;
;;;   - no configuration file: bootcfg is a note, not an extlinux.conf, so
;;;     nothing is written under /boot and no second boot configuration exists
;;;     to disagree with config.txt;
;;;   - no menu entries: there is no menu — the firmware reads config.txt.
;;;
;;; It is still a real <bootloader>, not a stub that only satisfies the type
;;; check: `guix system build' and `guix system image' evaluate and lower it,
;;; and `guix system reconfigure' on the card leaves the FAT untouched.

(define-module (rpi bootloader)
  #:use-module (gnu bootloader)
  #:use-module (guix gexp)
  #:export (%direct-kernel-bootloader
            direct-kernel-boot-notes))

;; The configuration-file generator Guix calls from `operating-system-bootcfg'.
;; It must return something lowerable, so it returns a file that says what the
;; boot chain is — deliberately not a bootloader configuration: nothing reads
;; it, and writing an extlinux.conf-shaped file is the bug this record exists
;; to avoid.
(define* (direct-kernel-boot-notes config entries
                                   #:key system old-entries
                                   #:allow-other-keys)
  "Return a note describing the boot chain of a directly booted board.
CONFIG is the <bootloader-configuration>, ENTRIES the menu entries Guix would
have written; both are ignored, because the firmware reads config.txt and
cmdline.txt from the FAT boot partition instead."
  (plain-file "direct-kernel-boot.txt"
              (string-append
               "# This board has no bootloader.\n"
               "#\n"
               "# The firmware reads config.txt (kernel=, initramfs, dtoverlay=)\n"
               "# and cmdline.txt from the FAT boot partition and starts the\n"
               "# kernel itself. Both files are written by rpi-boot-populate\n"
               "# against the mounted partition; the kernel, initrd and device\n"
               "# trees are copied by the same run.\n"
               "#\n"
               "# No extlinux.conf, no menu, no bootloader package is installed:\n"
               "# this record exists because <operating-system> requires one.\n")))

(define-public %direct-kernel-bootloader
  (bootloader
   (name 'direct-kernel)
   (package #f)
   (installer #f)
   ;; A PATH, not #f. `guix system image' builds the root partition by calling
   ;; (install-boot-config bootcfg bootcfg-location root) whenever bootcfg is
   ;; true, and does (string-append mount-point bootcfg-location): with #f here
   ;; the image build dies with "Wrong type (expecting string): #f" AFTER the
   ;; kernel has been compiled. The generated note is copied to this path on the
   ;; root file system, which is harmless and never read by anything; what
   ;; matters is that no bootloader configuration is installed.
   (configuration-file "/etc/direct-kernel-boot.txt")
   (configuration-file-generator direct-kernel-boot-notes)))
