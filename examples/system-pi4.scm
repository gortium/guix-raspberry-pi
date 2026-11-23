;;; examples/system-pi4.scm — a Pi 4 / CM4 that boots to a login prompt.
;;;
;;; The bcm2711 twin of system-cm5.scm, and deliberately no bigger: the kernel
;;; this channel builds for that SoC, the firmware a 43455 radio needs, the two
;;; file-system labels the image sets, ssh on the network. Everything else — a
;;; desktop, an editor, your tools — is yours to add.
;;;
;;; What is NOT optional here, and why:
;;;   - the zstd variant: guix's initrd machinery cannot read .ko.xz, so any
;;;     non-empty initrd-modules needs zstd modules; the console variant adds
;;;     the USB serial console a headless carrier has no other way to show;
;;;   - the file-system labels: guix's initrd resolves bare labels, never
;;;     LABEL=...;
;;;   - no kernel-arguments: the cmdline has one owner, the tool that fills the
;;;     boot partition (see docs/boot-chain.org). A list here would be a second
;;;     copy that silently disagrees with that writer.
;;;
;;; EXPECTED, NOT TESTED ON HARDWARE: none of this has run on a 2711 board.
;;; docs/boards.org says what that claim covers.

(define-module (examples system-pi4)
  #:use-module (gnu)
  #:use-module (gnu system file-systems)
  #:use-module (gnu bootloader)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services ssh)
  #:use-module (gnu services networking)
  #:use-module (gnu services desktop)           ;elogind-service-type
  #:use-module (gnu packages)
  #:use-module (nongnu packages linux)          ;linux-firmware
  #:use-module (rpi bootloader)                 ;%direct-kernel-bootloader
  #:use-module (rpi kernel)
  #:use-module (rpi firmware))

(operating-system
  (host-name "pi4")
  (timezone "Etc/UTC")
  (locale "en_US.utf8")

  (kernel linux-rpi-2711-zstd-console)

  ;; Empty on purpose, and this is the honest answer for this board rather than
  ;; a placeholder. The 2711 root device is the emmc2 controller
  ;; (brcm,bcm2711-emmc2), which sdhci-iproc drives — CONFIG_MMC_SDHCI_IPROC=y
  ;; in bcm2711_defconfig — on both the Pi 4 SD slot and the CM4 eMMC, and
  ;; ext4 is built in (CONFIG_EXT4_FS=y). Nothing the initrd needs to mount the
  ;; root file system is a module. The CM5 example lists sdhci-of-dwcmshc
  ;; because that controller is RP1's on bcm2712; it does not exist here, and
  ;; listing it would fail the build or, worse, look like it mattered.
  (initrd-modules '())

  (firmware (list linux-firmware
                  rpi-brcm43455-firmware
                  rpi-bt-firmware
                  rpi-regdb-firmware))

  ;; Direct-kernel boot: the firmware reads config.txt and cmdline.txt off the
  ;; FAT and loads the kernel itself, so this system has no bootloader. The
  ;; record Guix requires is the platform's no-op: no package, no installer, no
  ;; configuration file, no menu entries — nothing writes /boot/extlinux/.
  (bootloader (bootloader-configuration
               (bootloader %direct-kernel-bootloader)
               (targets '("/dev/mmcblk0"))))

  (file-systems
   (append
    (list (file-system
            (device (file-system-label "guix-root"))
            (mount-point "/")
            (type "ext4"))
          (file-system
            (device (file-system-label "guix-boot"))
            (mount-point "/boot")
            (type "vfat")))
    %base-file-systems))

  (users (cons* (user-account
                 (name "pi")
                 (comment "local user")
                 (group "users")
                 (supplementary-groups '("wheel" "video" "audio" "render"
                                         "netdev" "dialout"))
                 (home-directory "/home/pi"))
                %base-user-accounts))

  (groups (cons* (user-group (name "render"))
                 %base-groups))

  (sudoers-file
   (plain-file "sudoers"
               "root ALL=(ALL) ALL\n%wheel ALL=(ALL) ALL\n"))

  ;; glibc-locales is not decoration: without it the declared locale does not
  ;; exist and every guix command prints the GUIX_LOCPATH hint.
  (packages
   (append (specifications->packages
            (list "glibc-locales" "sudo" "kmod" "dosfstools" "parted"))
           %base-packages))

  (services
   (append
    (list
     (service elogind-service-type)

     ;; Password login on: a fresh board has no authorized_keys yet.
     (service openssh-service-type
              (openssh-configuration
               (password-authentication? #t)))

     (service network-manager-service-type)
     ;; NetworkManager refuses to start without a wireless daemon; brcmfmac
     ;; works with wpa_supplicant.
     (service wpa-supplicant-service-type)

     ;; No RTC battery on these boards: the clock starts at the epoch on every
     ;; power-on, and HTTPS, guix signatures and logs all depend on it.
     (service ntp-service-type))
    (modify-services %base-services
      ;; bordeaux carries a reliable aarch64 closure; ci.guix hangs builds.
      ;; No public server carries the kernel this channel builds, so a first
      ;; build is a real build.
      (guix-service-type config =>
        (guix-configuration
         (inherit config)
         (substitute-urls '("https://bordeaux.guix.gnu.org"))))))))
