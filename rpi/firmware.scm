;;; rpi/firmware.scm — the firmware a Raspberry Pi kernel needs, in the names it
;;; actually asks for.
;;;
;;; Three packages, three real failures, all of them silent at the console:
;;;
;;;   brcm43455   linux-firmware ships brcmfmac43455-sdio.bin as .bin.zst. A
;;;                kernel built without CONFIG_FW_LOADER_COMPRESS_ZSTD never
;;;                tries the .zst name: firmware_class asks for .bin, gets ENOENT,
;;;                and brcmfmac dies with `brcm_sdio_htclk: HT Avail timeout'.
;;;                WiFi is dead while every package looks installed.
;;;   BCM4345C0   linux-firmware carries no .hcd for the 4345, so hci_uart_bcm
;;;                prints `firmware Patch file not found' and hci0 never appears.
;;;   regulatory  without regulatory.db, cfg80211 logs `Direct firmware load for
;;;                regulatory.db failed' and the radio runs on the world domain,
;;;                which locks out part of 5 GHz. Guix's wireless-regdb package
;;;                builds an UNSIGNED db on purpose, and
;;;                CONFIG_CFG80211_REQUIRE_SIGNED_REGDB rejects it — hence the
;;;                upstream tarball, with the signed pair it ships.
;;;
;;; None of this is board-specific: these are the radio of every bcm2711/bcm2712
;;; board with a Cypress 43455 combo chip.

(define-module (rpi firmware)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix download)                 ;url-fetch (the BCM4345C0 blob)
  #:use-module (guix build-system trivial)
  #:use-module (nongnu packages linux)         ;linux-firmware lives HERE
  #:use-module (gnu packages base)             ;tar
  #:use-module (gnu packages compression)      ;zstd
  #:use-module (gnu packages linux)            ;wireless-regdb
  #:export (rpi-brcm43455-firmware
            rpi-bt-firmware
            rpi-regdb-firmware))

;; The driver asks for .bin, .txt and .clm_blob, and for nothing else: a kernel
;; without the zstd loader scans those three names and gives up. Every file
;; linux-firmware ships compressed under this prefix is therefore installed
;; uncompressed, board .txt included — the board name in those comes from the
;; device tree, never from here.
(define-public rpi-brcm43455-firmware
  (package
    (name "rpi-brcm43455-firmware")
    (version (package-version linux-firmware))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out   (assoc-ref %outputs "out"))
                 (dst   (string-append out "/lib/firmware/brcm"))
                 (src   #$(file-append linux-firmware "/lib/firmware/brcm"))
                 (zstd  #$(file-append zstd "/bin/zstd"))
                 (files (find-files src "brcmfmac43455-sdio.*\\.zst$")))
            ;; An empty output would look like a successful package and leave
            ;; the radio dead, so a rename upstream is an error, not a no-op.
            (when (null? files)
              (error "no compressed BCM43455 firmware in linux-firmware" src))
            (mkdir-p dst)
            (for-each
             (lambda (f)
               (invoke zstd "-d" "-q" "-f" f
                       "-o" (string-append dst "/" (basename f ".zst"))))
             files)))))
    (native-inputs (list zstd))
    (home-page "https://github.com/RPi-Distro/firmware-nonfree")
    (synopsis "Uncompressed BCM43455 Wi-Fi firmware")
    (description
     "Decompressed brcmfmac43455 firmware files, installed under the names a
kernel without a zstd firmware decompressor requests.")
    (license (package-license linux-firmware))))

;; hci_uart_bcm builds its firmware name list from the chip and the device-tree
;; root compatible string: "brcm/<chip>.<dt-board>.hcd" first, then
;; "brcm/<chip>.hcd". Only the generic name is installed here — the driver falls
;; back to it, and a copy named after a device tree would make this package
;; correct for one board only.
(define-public rpi-bt-firmware
  (package
    (name "rpi-bt-firmware")
    (version "1.0")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "https://raw.githubusercontent.com/RPi-Distro/"
                    "bluez-firmware/master/broadcom/BCM4345C0.hcd"))
              (sha256
               (base32
                "0b54vsv73brvn8s2dps0k4kpq25jjm9bg3ywjsga34ddvmvmxi2i"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out (assoc-ref %outputs "out"))
                 (dst (string-append out "/lib/firmware/brcm"))
                 (src (assoc-ref %build-inputs "source")))
            (mkdir-p dst)
            (copy-file src (string-append dst "/BCM4345C0.hcd"))))))
    (home-page "https://github.com/RPi-Distro/bluez-firmware")
    (synopsis "BCM4345 Bluetooth patch file")
    (description
     "The BCM4345C0 firmware patch file a Cypress 43455 combo radio needs;
linux-firmware does not carry it, so hci0 cannot come up without it.")
    (license (package-license linux-firmware))))

(define-public rpi-regdb-firmware
  (package
    (name "rpi-regdb-firmware")
    (version (package-version wireless-regdb))
    (source (package-source wireless-regdb))
    (build-system trivial-build-system)
    (native-inputs (list tar zstd))
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out (assoc-ref %outputs "out"))
                 (dst (string-append out "/lib/firmware/regdb-src"))
                 (src (assoc-ref %build-inputs "source")))
            ;; The origin is a .tar.zst (guix re-compresses channel sources),
            ;; so tar needs zstd on PATH, not xz.
            (setenv "PATH"
                    (string-append (assoc-ref %build-inputs "tar") "/bin:"
                                   (assoc-ref %build-inputs "zstd") "/bin"))
            (mkdir-p dst)
            (invoke "tar" "xf" src "-C" dst)
            (for-each
             (lambda (name)
               (let ((found (find-files dst (string-append "^" name "$"))))
                 (unless (pair? found)
                   (error "regulatory file missing from the tarball" name))
                 (install-file (car found)
                               (string-append out "/lib/firmware"))))
             '("regulatory.db" "regulatory.db.p7s"))
            ;; The scratch extraction has no business in a firmware union.
            (delete-file-recursively dst)))))
    (home-page "https://wireless.wiki.kernel.org/en/developers/regulatory/wireless-regdb")
    (synopsis "Signed wireless regulatory database")
    (description
     "The signed regulatory.db and its detached signature, installed under
/lib/firmware so cfg80211 accepts it instead of falling back to the built-in
world regulatory domain.")
    (license (package-license wireless-regdb))))
