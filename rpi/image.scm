;;; rpi/image.scm — the platform's disk image, as a constructor.
;;;
;;; One image definition, one partition path: a FAT boot partition the firmware
;;; can read and an ext4 root partition that holds the Guix store. Every number
;;; below is a keyword argument, because a carrier that starts its first
;;; partition at a sector its boot ROM expects must not need a copy of this
;;; file.
;;;
;;;   os                        the <operating-system> to put on the root
;;;                             partition (required)
;;;   boot-size                 boot partition size in bytes; 512 MiB by
;;;                             default, enough for kernel, initrd, base device
;;;                             trees, overlays and the VideoCore blobs
;;;   boot-offset               first sector of the boot partition in bytes;
;;;                             8 MiB by default, the layout this platform's
;;;                             carrier uses
;;;   boot-label                file-system label of the boot partition
;;;   boot-file-system          "fat32" by default — see below
;;;   boot-file-system-options  extra mkfs options, none by default
;;;   root-size                 bytes or 'guess; 'guess fills the image
;;;   root-label                file-system label of the root partition
;;;   root-file-system          "ext4" by default
;;;   root-file-system-options  mkfs options; the U-Boot-compatible set by
;;;                             default
;;;
;;; WHAT THE IMAGE DOES NOT CONTAIN: kernel, initrd, config.txt, cmdline.txt,
;;; device trees. The boot partition is created empty and stays empty, because
;;; those files have one writer, rpi-boot-populate, and that writer runs against
;;; the mounted partition (see docs/boot-chain.org). An image that populated
;;; them would be a second writer, and the two would drift the first time one of
;;; them changed.
;;;
;;; Each default below is a measured invariant, not a preference. The comment
;;; on each one says what breaks when it is changed.

(define-module (rpi image)
  #:use-module (gnu image)
  #:use-module (gnu system)                  ;operating-system?
  #:use-module (gnu system image)
  #:use-module (guix gexp)                   ;gexp, for the boot initializer
  #:export (rpi-image))

(define (exact-positive-integer? value)
  (and (integer? value) (exact? value) (positive? value)))

(define* (rpi-image #:key
                    os
                    (boot-size (* 512 (expt 2 20)))
                    (boot-offset (* 16384 512))
                    (boot-label "guix-boot")
                    (boot-file-system "fat32")
                    (boot-file-system-options '())
                    (root-size 'guess)
                    (root-label "guix-root")
                    (root-file-system "ext4")
                    (root-file-system-options '("-O" "^metadata_csum,^64bit")))
  "Return an <image> for a board that boots the kernel directly from a FAT
partition. OS is placed on the root partition; the boot partition is left empty
for the boot-chain tool to fill."
  (unless os
    (error "rpi-image: #:os is required — an image without a system has no root"))
  (unless (operating-system? os)
    (error "rpi-image: #:os must be an <operating-system> record" os))
  (unless (exact-positive-integer? boot-size)
    (error "rpi-image: #:boot-size must be a positive number of bytes" boot-size))
  (unless (and (exact-positive-integer? boot-offset)
               (zero? (modulo boot-offset 512)))
    (error "rpi-image: #:boot-offset must be a whole number of 512-byte MBR sectors"
           boot-offset))
  (unless (and (string? boot-label) (not (string-null? boot-label)))
    (error "rpi-image: #:boot-label must be a non-empty string" boot-label))
  (unless (and (string? root-label) (not (string-null? root-label)))
    (error "rpi-image: #:root-label must be a non-empty string" root-label))
  (when (string=? boot-label root-label)
    (error "rpi-image: boot and root labels must differ — the initrd resolves root= by bare label, so two partitions carrying one label are ambiguous"
           boot-label))

  (image
   (format 'disk-image)
   (operating-system os)

   ;; MBR, not GPT. The firmware scans MBR partition types; GPT puts its
   ;; protective entry and its partition array where a boot ROM that only knows
   ;; the MBR does not look.
   (partition-table-type 'mbr)

   (partitions
    (list
     (partition
      (size boot-size)

      ;; 16384 sectors = 8 MiB, the layout the carrier's own image uses: its
      ;; first partition starts at sector 16384 and its second at sector
      ;; 1064960. A matching image built at 1 MiB (sector 2048, where Guix's
      ;; own esp sits) was flashed four times and never reached the kernel —
      ;; the root file system stayed clean, so it was never mounted either. The
      ;; sector offset was the only structural difference left, with the whole
      ;; FAT content identical. Keep the vendor offset unless the board's boot
      ;; ROM says otherwise.
      (offset boot-offset)

      (label boot-label)

      ;; "fat32", never "vfat". Guix maps this string to BOTH the mkfs
      ;; invocation and the MBR partition type: "vfat" means mkdosfs -F 16 and
      ;; type 0x0e, "fat32" means mkdosfs -F 32 and type 0x0c. A FAT16 boot
      ;; partition of this size lands exactly on the 65535-cluster limit, and
      ;; the boot ROMs this platform targets are documented against FAT32 at
      ;; type 0x0c.
      (file-system boot-file-system)
      (file-system-options boot-file-system-options)

      ;; 'boot only, never 'esp. 'esp writes MBR type 0xef (EFI System), and
      ;; the boot ROM scans for FAT types (0x01, 0x04, 0x06, 0x0b, 0x0c,
      ;; 0x0e) — a 0xef partition is invisible to it: no config.txt read, no
      ;; kernel, no error, black screen.
      (flags '(boot))

      ;; Required, and it does nothing on purpose. Without an initializer Guix
      ;; falls back to initialize-root-partition for EVERY partition, so it
      ;; would copy the whole store into this FAT: the boot partition fills up
      ;; and the image build dies with "mcopy: Disk full". The directory still
      ;; has to exist, because the FAT image builder scans it.
      (initializer
       (gexp (lambda* (root #:key #:allow-other-keys)
               (unless (file-exists? root)
                 (mkdir root))))))

     (partition
      (size root-size)

      ;; No offset: zero is what the image builder reads as "place this
      ;; partition after the previous one". An explicit offset would have to be
      ;; past boot-offset + boot-size, and Guix's own root-offset (1 MiB) sits
      ;; inside the boot partition's span — "partition guix-root overlaps
      ;; previous partition guix-boot".
      (label root-label)
      (file-system root-file-system)

      ;; U-Boot cannot mount ext4 with metadata_csum or 64bit, which is why
      ;; Guix's own root partition disables both. A board that boots through
      ;; U-Boot, or a carrier that has to hand the root over to one, keeps
      ;; working with this set.
      (file-system-options root-file-system-options)

      ;; No initializer either, but here the default is the wanted one:
      ;; initialize-root-partition populates the store and the system's kernel
      ;; on the ext4 root.
      )))))
