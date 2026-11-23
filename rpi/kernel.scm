;;; rpi/kernel.scm — the Raspberry Pi downstream kernel, as a constructor.
;;;
;;; This module is the reason the channel exists: it turns the rpi-6.12.y tree
;;; into a kernel package, with the pieces a board may need exposed as keyword
;;; arguments instead of copied code.
;;;
;;;   board            bcm2711 (Pi 4, CM4) or bcm2712 (Pi 5, CM5) — picks the
;;;                    defconfig and the page size; the rest of the machinery
;;;                    is identical
;;;   page-size        4096 or 16384; defaults to the board's answer, and an
;;;                    explicit value wins — except 16 KiB on bcm2711, which
;;;                    is refused
;;;   module-compress  "xz" (defconfig default) or "zstd"
;;;   patches          the board's patch list; empty for a bare board
;;;   kconfig          extra .config lines; %generic-kconfig by default, and a
;;;                    board that needs panel/power symbols passes its own list
;;;
;;; WHY ZSTD MATTERS: guix's initrd machinery can only read .gz and .ko.zst
;;; (gnu/build/linux-modules.scm); a kernel whose modules are .ko.xz cannot be
;;; listed in initrd-modules at all. Any board that needs a driver in the initrd
;;; must therefore use the zstd variant.

(define-module (rpi kernel)
  #:use-module (gnu packages)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages algebra)                   ;bc
  #:use-module (gnu packages bison)                     ;kernel build tools
  #:use-module (gnu packages flex)
  #:use-module (gnu packages perl)
  #:use-module ((gnu packages tls) #:prefix tls:)        ;openssl
  #:use-module (gnu packages pkg-config)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix download)
  #:use-module (guix build-system gnu)
  #:use-module (guix build utils)
  #:use-module (guix utils)
  #:export (%rpi-kernel-source
            %rpi-kernel-version
            %generic-kconfig
            %console-gadget-kconfig
            make-linux-rpi
            linux-rpi
            linux-rpi-4k
            linux-rpi-4k-zstd
            linux-rpi-4k-zstd-console
            linux-rpi-2711
            linux-rpi-2711-zstd
            linux-rpi-2711-zstd-console))

;; The downstream tree, pinned by tag. A tarball, not a git checkout: the
;; channel must not need a git binary or network access beyond the archive.
;;
;; rpi-6.12.y at stable_20250916 is Linux 6.12.47. Moving this pin changes
;; every board's kernel at once, which is why it lives here and not per board.
(define %rpi-kernel-version "6.12.47-rpi")

(define %rpi-kernel-source
  (origin
    (method url-fetch)
    (uri (string-append
          "https://github.com/raspberrypi/linux/archive/refs/tags/"
          "stable_20250916.tar.gz"))
    (file-name "linux-rpi-6.12.47.tar.gz")
    (sha256
     (base32 "1ws70vjbpv7ngi7pldwcwbjqr9amv1qln8q8ywfbfw3rd5wzwfa6"))))

;; Defconfig per SoC. Anything not listed here is not supported by this
;; channel: Pi 3 and Zero are 32-bit and boot through u-boot, which is a
;; different boot chain, not a different defconfig.
(define %board-defconfig
  '((bcm2711 . "bcm2711_defconfig")
    (bcm2712 . "bcm2712_defconfig")))

;; Page size per SoC — the default, not a mandate: a 2712 can be asked for
;; 4096 and a 2711 already is 4096. 16 KiB pages on a 2711 are refused below,
;; because the 2711 defconfig selects ARM64_4K_PAGES (16 KiB is the A76+ /
;; BCM2712 configuration) and the Pi 4 firmware only loads =kernel8.img=, so a
;; 16 KiB kernel there is not slow, it is a card that never starts.
(define %board-page-size
  '((bcm2711 . 4096)
    (bcm2712 . 16384)))

;; What the platform asks for on any board. Small on purpose: drivers that are
;; merely convenient are the user's business, and every line here is one more
;; symbol a board's patches must keep valid.
;;
;; USB_ACM and SND_USB_AUDIO are built IN (=y), not modular: a minimal module
;; tree without modules.dep cannot autoload them, and a USB serial adapter or a
;; USB sound card that silently does nothing is a bad first impression.
(define %generic-kconfig
  '("CONFIG_INPUT_UINPUT=y"
    "CONFIG_DRM=y"
    "CONFIG_DRM_VC4=y"
    "CONFIG_DRM_VC4_HDMI_CEC=n"
    "CONFIG_SND_SOC=y"
    "CONFIG_SND_SOC_PWM=y"
    "CONFIG_BRCMFMAC=y"
    "CONFIG_I2C_BCM2708=y"
    "CONFIG_SPI_BCM2835=y"
    "CONFIG_USB_ACM=y"
    "CONFIG_SND_USB_AUDIO=y"))

;; Legacy USB gadget serial, built in.
;;
;; A board with no HDMI and no broken-out UART has no visible kernel console,
;; and the USB-C port is the only way out. With g_serial built in,
;; `console=ttyGS0,115200' starts printing as soon as the DWC2 controller is
;; up — before the initramfs is unpacked — so the log survives exactly the case
;; that cannot be told apart from a kernel that never ran.
;;
;; DUAL_ROLE, not peripheral-only: the peripheral-only driver forces device mode
;; and prints "Configuration mismatch", which makes a USB hub hanging off the
;; same controller (a keyboard, a trackpad) impossible to enumerate.
(define %console-gadget-kconfig
  '("CONFIG_USB_LIBCOMPOSITE=y"
    "CONFIG_USB_G_SERIAL=y"
    "CONFIG_USB_CONFIGFS=y"
    "CONFIG_USB_GADGET=y"
    "CONFIG_USB_DWC2=y"
    "CONFIG_USB_DWC2_DUAL_ROLE=y"))

;; Page size is a property of the SoC family, and getting it wrong is not a
;; performance question: the firmware names the image after it, and this tree's
;; 2712 defconfig carries `-v8-16k' in LOCALVERSION.
;;
;; 4K needs VA_BITS_39 spelled out: 16K pages select a 47-bit VA, and 47 is not
;; an offered choice once 4K pages are on (Kconfig offers 39/42/48/52), so
;; leaving CONFIG_ARM64_VA_BITS_47=y lets olddefconfig drop it silently.
;;
;; The -v8-4k localversion only corrects the 2712 defconfig's -v8-16k; a 2711
;; defconfig says nothing about page size and must not start now.
(define (page-size-kconfig board page-size)
  (case page-size
    ((4096)
     (append '("# CONFIG_ARM64_16K_PAGES is not set"
               "CONFIG_ARM64_4K_PAGES=y"
               "CONFIG_ARM64_VA_BITS_39=y")
             (if (eq? board 'bcm2712)
                 '("CONFIG_LOCALVERSION=\"-v8-4k\"")
                 '())))
    ((16384)
     '("CONFIG_ARM64_16K_PAGES=y"
       "# CONFIG_ARM64_4K_PAGES is not set"))
    (else
     (error "page-size must be 4096 or 16384" page-size))))

(define* (module-compress-kconfig #:optional (mode "xz"))
  (if (string=? mode "zstd")
      '("CONFIG_MODULE_COMPRESS_ZSTD=y"
        "# CONFIG_MODULE_COMPRESS_XZ is not set"
        "CONFIG_MODULE_DECOMPRESS=y")
      '()))

(define* (make-linux-rpi #:key
                         (board 'bcm2712)
                         (page-size #f)
                         (localversion "")
                         (name "linux-rpi")
                         (module-compress "xz")
                         (patches '())
                         (kconfig %generic-kconfig)
                         (synopsis "Linux kernel for Raspberry Pi boards")
                         (description
                          "The Raspberry Pi downstream kernel (rpi-6.12.y),
built for a bcm2711 or bcm2712 board."))
  (let* ((defconfig (assoc-ref %board-defconfig board))
         (page-size (or page-size (assoc-ref %board-page-size board))))
    (unless defconfig
      (error "no defconfig for board" board))
    ;; Refused rather than quietly forced: a 16 KiB kernel on a bcm2711 is a
    ;; kernel the board's firmware will not load, and the failure looks like
    ;; dead hardware. The caller asked for a specific page size, so say no.
    (when (and (eq? board 'bcm2711) (= page-size 16384))
      (error (string-append
              "bcm2711 uses 4096-byte pages: 16 KiB pages need bcm2712 "
              "(and the Pi 4 firmware only boots a 4 KiB kernel8.img); "
              "asked for " (number->string page-size) " on bcm2711")))
    (package
      (name name)
      (version %rpi-kernel-version)
      (source (origin
                (inherit %rpi-kernel-source)
                (patches patches)))
      (build-system gnu-build-system)
      (supported-systems '("aarch64-linux"))
      (arguments
       (list
        #:make-flags
        #~(list "ARCH=arm64"
                (string-append "LOCALVERSION=" #$localversion)
                "Image" "modules" "dtbs")
        #:phases
        #~(modify-phases %standard-phases
            (add-before 'configure 'set-cross-toolchain
              (lambda* (#:key target #:allow-other-keys)
                ;; make reads CROSS_COMPILE from the environment; set it only
                ;; when cross-compiling (target is #f for native aarch64).
                (when target
                  (setenv "CROSS_COMPILE" (string-append target "-")))
                #t))
            (replace 'configure
              (lambda* (#:key make-flags #:allow-other-keys)
                (invoke "make" "ARCH=arm64" #$defconfig)
                (let ((port (open-file ".config" "a")))
                  (for-each (lambda (opt)
                              (display opt port) (newline port))
                            (append '#$(page-size-kconfig board page-size)
                                    '#$kconfig
                                    '#$(module-compress-kconfig module-compress)))
                  (close-port port))
                (invoke "make" "ARCH=arm64" "olddefconfig")))
            (replace 'build
              (lambda* (#:key make-flags #:allow-other-keys)
                (apply invoke "make" "-j"
                       (number->string (parallel-job-count))
                       make-flags)))
            (replace 'install
              (lambda* (#:key outputs #:allow-other-keys)
                (let ((out (assoc-ref outputs "out"))
                      (moddir (string-append (assoc-ref outputs "out")
                                             "/lib/modules"))
                      (dtbdir (string-append (assoc-ref outputs "out") "/dtbs")))
                  (for-each (lambda (f) (install-file f out))
                            (find-files "."
                                        "^(Image|zImage|bzImage|vmlinuz|System[.]map|Module[.]symvers)$"))
                  (unless (null? (find-files "." "\\.dtb$"))
                    (mkdir-p dtbdir)
                    (invoke "make" "ARCH=arm64"
                            (string-append "INSTALL_DTBS_PATH=" dtbdir)
                            "dtbs_install"))
                  (mkdir-p moddir)
                  (invoke "make" "ARCH=arm64"
                          (string-append "LOCALVERSION=" #$localversion)
                          "DEPMOD=true"
                          (string-append "INSTALL_MOD_PATH=" out)
                          "INSTALL_MOD_STRIP=1" "modules_install"))))
            (delete 'check))))
      ;; `make modules_install' calls zstd when module-compress is "zstd"; xz
      ;; ships in %standard-inputs, so the default build needs nothing extra.
      (native-inputs (append (list bc bison flex perl tls:openssl pkg-config)
                             (if (string=? module-compress "zstd")
                                 (list zstd)
                                 '())))
      (inputs (list elfutils))
      (home-page "https://github.com/raspberrypi/linux")
      (synopsis synopsis)
      (description description)
      (license (list gpl2 lgpl2.1)))))

;; 16K pages, xz modules: the 2712 default, and the image must then be named
;; kernel_2712.img — the firmware only accepts that name for a 16K kernel.
(define-public linux-rpi (make-linux-rpi))

;; 4K pages, xz modules. Same kernel, different page size; the localversion
;; carries -v8-4k because the tree's defconfig hardcodes -v8-16k, which would
;; then lie about the page size everywhere the module directory is quoted.
(define-public linux-rpi-4k
  (make-linux-rpi #:page-size 4096
                  #:localversion "-4k"
                  #:name "linux-rpi-4k"))

;; 4K pages, zstd modules: the only variant whose modules guix's initrd
;; machinery can read, so the only one usable when initrd-modules is non-empty.
(define-public linux-rpi-4k-zstd
  (make-linux-rpi #:page-size 4096
                  #:localversion "-4k-zstd"
                  #:name "linux-rpi-4k-zstd"
                  #:module-compress "zstd"))

;; 4K pages, zstd modules, USB serial console compiled in: what a CM5 in a
;; headless carrier actually needs.
(define-public linux-rpi-4k-zstd-console
  (make-linux-rpi #:board 'bcm2712
                  #:page-size 4096
                  #:localversion "-4k-zstd-console"
                  #:name "linux-rpi-4k-zstd-console"
                  #:module-compress "zstd"
                  #:kconfig (append %console-gadget-kconfig %generic-kconfig)))

;; Return the plain 16K package so `guix build -f rpi/kernel.scm' works.
linux-rpi

;;; bcm2711 — Pi 4 and CM4.
;;;
;;; No page size is passed: the constructor takes it from the board, which is
;;; 4096 here. The -2711 localversion keeps the module directories apart from
;;; the 2712 kernels, whose release name is otherwise the same string.

;; 4K pages, xz modules: the plain Pi 4 kernel, and the only page size its
;; firmware will boot.
(define-public linux-rpi-2711
  (make-linux-rpi #:board 'bcm2711
                  #:name "linux-rpi-2711"
                  #:localversion "-2711"))

;; 4K pages, zstd modules: the bcm2711 kernel a system can list initrd-modules
;; against.
(define-public linux-rpi-2711-zstd
  (make-linux-rpi #:board 'bcm2711
                  #:name "linux-rpi-2711-zstd"
                  #:localversion "-2711-zstd"
                  #:module-compress "zstd"))

;; 4K pages, zstd modules, USB serial console compiled in: a CM4 on a carrier
;; with no display has the same "is it running at all" problem as the CM5.
(define-public linux-rpi-2711-zstd-console
  (make-linux-rpi #:board 'bcm2711
                  #:name "linux-rpi-2711-zstd-console"
                  #:localversion "-2711-zstd-console"
                  #:module-compress "zstd"
                  #:kconfig (append %console-gadget-kconfig %generic-kconfig)))
