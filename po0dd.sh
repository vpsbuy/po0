#!/bin/bash
# =========================================
#  po0dd.sh
#  Auto Install Debian 12 (bookworm)
#  via mirrors.tencent.com (无人值守 DD)
#
#  特性：
#    - 自动识别系统盘（/dev/vda -> /dev/sda -> /dev/nvme0n1）
#    - 支持 -passwd 指定 root 密码，不传则随机生成
#    - 支持 -port   指定 SSH 端口，默认 22
#    - 安装完成后开启 root 密码登录 + SSH
#    - 密码写入 /root/initial_root_password.txt
#
#  使用示例：
#    bash po0dd.sh
#    bash po0dd.sh -passwd MyStrongPwd
#    bash po0dd.sh -port 60022
#    bash po0dd.sh -passwd Mjj2025 -port 2222
#
#  注意：会整盘重装系统盘，数据全部清空！
# =========================================

set -e

# ======== 默认配置（可改） ========
DEBIAN_RELEASE="bookworm"       # Debian 12 = bookworm
HOSTNAME="debian"               # 安装后主机名
TIMEZONE="Asia/Shanghai"        # 时区
MIRROR_HOST="mirrors.tencent.com"

ROOT_PASSWORD=""                # 默认留空，后面用 -passwd 覆盖，留空则随机
ALLOW_WEAK_PASSWORD=true        # 是否允许弱密码（true/false）

SSH_PORT="22"                   # 默认 SSH 端口，可被 -port 覆盖

# 是否禁止安装过程中的 IPv6（部分国内网络 IPv6 有坑，可选）
DISABLE_IPV6=true
# ================================

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

usage() {
  cat <<EOF
用法:
  bash po0dd.sh [-passwd MyPassword] [-port 22]

说明:
  -passwd  指定 root 密码；不指定则自动生成随机密码
  -port    指定 SSH 端口（默认: ${SSH_PORT}）

示例:
  bash po0dd.sh                     # 随机 root 密码 + SSH 22
  bash po0dd.sh -passwd MyStrongPwd # 自定义密码 + SSH 22
  bash po0dd.sh -port 60022         # 随机密码 + SSH 60022
  bash po0dd.sh -passwd P@ss -port 2222
EOF
}

# ------- 参数解析（只有 passwd / port） -------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -passwd|--passwd)
      ROOT_PASSWORD="$2"
      shift 2
      ;;
    -port|--port)
      SSH_PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${YELLOW}[!] 未知参数: $1${NC}"
      usage
      exit 1
      ;;
  esac
done

# ------- 自动检测系统盘 DISK -------
detect_disk() {
  if [[ -b /dev/vda ]]; then
    echo "/dev/vda"
  elif [[ -b /dev/sda ]]; then
    echo "/dev/sda"
  elif [[ -b /dev/nvme0n1 ]]; then
    echo "/dev/nvme0n1"
  else
    echo ""
  fi
}

DISK="$(detect_disk)"

if [[ -z "$DISK" ]]; then
  echo -e "${YELLOW}[!] 未能自动检测到系统盘（/dev/vda /dev/sda /dev/nvme0n1 都不存在）${NC}"
  echo -e "${YELLOW}[!] 请手动修改脚本中 detect_disk() 函数后重试。${NC}"
  exit 1
fi

# ------- 校验端口 -------
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
  echo -e "${YELLOW}[!] 端口必须是数字: $SSH_PORT${NC}"
  exit 1
fi
if (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  echo -e "${YELLOW}[!] 端口范围必须在 1-65535 之间: $SSH_PORT${NC}"
  exit 1
fi

# ------- 生成随机密码（如需要） -------
gen_random_password() {
  # 仅使用 A-Za-z0-9，避免 preseed 解析问题
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
}

if [[ -z "$ROOT_PASSWORD" || "$ROOT_PASSWORD" == "RANDOM" ]]; then
  ROOT_PASSWORD="$(gen_random_password)"
  RANDOM_PW=1
else
  RANDOM_PW=0
fi

echo -e "${BLUE}[*] po0dd 无人值守 Debian 12 安装启动...${NC}"

# ------- 基础检查 -------
if [[ $EUID -ne 0 ]]; then
  echo -e "${YELLOW}[!] 请用 root 运行本脚本${NC}"
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo -e "${YELLOW}[!] 自动检测到的系统盘 ${DISK} 不存在，请检查宿主环境${NC}"
  lsblk
  exit 1
fi

echo
echo -e "${YELLOW}严重警告：本操作将【整盘重装】 ${DISK}，所有数据将被彻底清空且无法恢复！${NC}"
echo -e "${YELLOW}当前配置：${NC}"
echo "  系统盘     : $DISK"
echo "  Debian 版本: $DEBIAN_RELEASE"
echo "  主机名     : $HOSTNAME"
echo "  时区       : $TIMEZONE"
echo "  镜像源     : http://${MIRROR_HOST}/debian"
echo "  SSH 端口   : $SSH_PORT"
if [[ $RANDOM_PW -eq 1 ]]; then
  echo -e "  root 密码  : （已自动生成随机密码，下方会显示）"
else
  echo "  root 密码  : $ROOT_PASSWORD"
fi

if [[ $RANDOM_PW -eq 1 ]]; then
  echo
  echo -e "${GREEN}[+] 本次随机生成的 root 密码：${ROOT_PASSWORD}${NC}"
  echo -e "${YELLOW}[!] 请务必先记下此密码，安装完成后用它 SSH 登录${NC}"
fi

echo
read -rp "请键入 YES （大写）以确认继续： " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  echo -e "${YELLOW}[!] 用户取消${NC}"
  exit 1
fi

# ======= 安装依赖（优先尝试用腾讯源） =======
ensure_tools() {
  need_cpio=0
  need_gzip=0
  need_wget=0

  command -v cpio >/dev/null 2>&1 || need_cpio=1
  command -v gzip >/dev/null 2>&1 || need_gzip=1
  command -v wget >/dev/null 2>&1 || need_wget=1

  if [[ $need_cpio -eq 0 && $need_gzip -eq 0 && $need_wget -eq 0 ]]; then
    return 0
  fi

  echo -e "${BLUE}[*] 正在尝试安装依赖：cpio gzip wget${NC}"

  if command -v apt-get >/dev/null 2>&1; then
    # 优先尝试直接 update
    if ! apt-get update -y >/dev/null 2>&1; then
      echo -e "${YELLOW}[!] apt update 失败，尝试切换为腾讯 Debian 源${NC}"
      if [[ -f /etc/apt/sources.list ]]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s)
      fi
      cat >/etc/apt/sources.list <<EOF
deb http://${MIRROR_HOST}/debian/ stable main contrib non-free non-free-firmware
deb http://${MIRROR_HOST}/debian/ stable-updates main contrib non-free non-free-firmware
deb http://${MIRROR_HOST}/debian-security stable-security main contrib non-free non-free-firmware
EOF
      apt-get update -y
    fi
    apt-get install -y cpio gzip wget
  elif command -v yum >/dev/null 2>&1; then
    yum install -y cpio gzip wget || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y cpio gzip wget || true
  elif command -v apk >/dev/null 2>&1; then
    apk update
    apk add cpio gzip wget
  else
    echo -e "${YELLOW}[!] 无法识别包管理器，请手动安装 cpio/gzip/wget 后重试${NC}"
    exit 1
  fi

  for cmd in cpio gzip wget; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo -e "${YELLOW}[!] 依赖安装失败：缺少 $cmd${NC}"
      exit 1
    fi
  done
}

ensure_tools

# ======= 准备目录与下载内核和 initrd =======
WORK_DIR="/boot/debian-autoinstall"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo -e "${BLUE}[*] 从腾讯镜像下载 debian-installer kernel & initrd...${NC}"

KERNEL_URL="http://${MIRROR_HOST}/debian/dists/${DEBIAN_RELEASE}/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux"
INITRD_URL="http://${MIRROR_HOST}/debian/dists/${DEBIAN_RELEASE}/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz"

wget -O linux "$KERNEL_URL"
wget -O initrd.gz "$INITRD_URL"

if [[ ! -s linux || ! -s initrd.gz ]]; then
  echo -e "${YELLOW}[!] 下载 linux/initrd.gz 失败，请检查能否访问 ${MIRROR_HOST}${NC}"
  exit 1
fi

echo -e "${GREEN}[+] debian-installer kernel & initrd 已下载${NC}"

# ======= 解包 initrd 并注入 preseed.cfg =======
echo -e "${BLUE}[*] 解包 initrd 并注入 preseed.cfg（无人值守参数 + SSH 修正 + 密码写入）...${NC}"

rm -rf initrd-dir
mkdir -p initrd-dir
cd initrd-dir

# 解包原 initrd
gzip -d -c ../initrd.gz | cpio -idmv

# 生成 preseed.cfg
cat > preseed.cfg <<EOF
### 本 preseed 由 po0dd.sh 自动生成 ###

# 语言与键盘
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

# 网络（自动获取 IP）
d-i netcfg/choose_interface select auto
d-i netcfg/disable_dhcp boolean false
d-i netcfg/get_hostname string ${HOSTNAME}
d-i netcfg/get_domain string localdomain

# 时区与时钟
d-i clock-setup/utc boolean true
d-i time/zone string ${TIMEZONE}
d-i clock-setup/ntp boolean true

# 镜像设置（使用腾讯镜像）
d-i mirror/country string manual
d-i mirror/http/hostname string ${MIRROR_HOST}
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i mirror/suite string ${DEBIAN_RELEASE}
d-i mirror/udeb/suite string ${DEBIAN_RELEASE}

# APT 相关（安全更新与更新源）
d-i apt-setup/use_mirror boolean true
d-i apt-setup/services-select multiselect security, updates
d-i apt-setup/security_host string ${MIRROR_HOST}
d-i apt-setup/security_path string /debian-security
d-i apt-setup/security_suite string ${DEBIAN_RELEASE}-security

# 分区（整盘自动分区，使用所有空间）
d-i partman-auto/method string regular
d-i partman-auto/disk string ${DISK}
d-i partman-auto/choose_recipe select atomic

d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# ROOT 用户设置
d-i passwd/root-login boolean true
d-i passwd/root-password password ${ROOT_PASSWORD}
d-i passwd/root-password-again password ${ROOT_PASSWORD}
d-i user-setup/allow-password-weak boolean ${ALLOW_WEAK_PASSWORD}
d-i passwd/make-user boolean false

# 软件选择（最小系统 + SSH）
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string curl wget vim openssh-server

# 禁用参与软件包普及度调查
popularity-contest popularity-contest/participate boolean false

# GRUB 安装
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string ${DISK}

# 安装结束自动重启
d-i finish-install/reboot_in_progress note

# ------- late_command：安装结束阶段强制打开 SSH/root 密码登录，设置端口，并写入密码文件 -------
d-i preseed/late_command string in-target sh -c 'apt-get update || true; \
  apt-get install -y openssh-server || true; \
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true; \
  if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then \
    sed -i "s/^PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config; \
  else \
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config; \
  fi; \
  if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then \
    sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config; \
  else \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config; \
  fi; \
  sed -i "/^Port /d" /etc/ssh/sshd_config; \
  echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config; \
  printf "Initial root password: ${ROOT_PASSWORD}\n" > /root/initial_root_password.txt; \
  chmod 600 /root/initial_root_password.txt 2>/dev/null || true; \
  systemctl enable ssh || true; \
  systemctl restart ssh || true'
EOF

# 重新打包 initrd，包含 preseed.cfg
find . | cpio -H newc -o | gzip -9 > ../initrd-preseed.gz

cd ..
mv initrd-preseed.gz initrd.gz
rm -rf initrd-dir

echo -e "${GREEN}[+] 已将 preseed.cfg 注入 initrd（无人值守安装 + SSH 修正 + 端口 + 密码文件）${NC}"

# ======= 写入 GRUB 启动项 =======
echo -e "${BLUE}[*] 写入 GRUB 启动项（重启后自动进入安装）...${NC}"

GRUB_SCRIPT="/etc/grub.d/05_po0_autoinstall"

cat > "$GRUB_SCRIPT" <<EOF
#!/bin/sh
exec tail -n +3 \$0

menuentry '*** po0 Auto Install Debian 12 (DD ALL ${DISK}) via Tencent ***' {
    insmod gzio
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    search --no-floppy --file /boot/debian-autoinstall/linux --set=root

    linux /boot/debian-autoinstall/linux \
        auto=true priority=critical \
        preseed/file=/preseed.cfg \
        debian-installer/locale=en_US.UTF-8 \
        keyboard-configuration/xkb-keymap=us \
        netcfg/choose_interface=auto \
        netcfg/disable_dhcp=false \
        mirror/country=manual \
        mirror/http/hostname=${MIRROR_HOST} \
        mirror/http/directory=/debian \
        mirror/http/proxy= \
        mirror/suite=${DEBIAN_RELEASE} \
        hostname=${HOSTNAME} domain=localdomain \
        ${DISABLE_IPV6:+ipv6.disable=1}

    initrd /boot/debian-autoinstall/initrd.gz
}
EOF

chmod +x "$GRUB_SCRIPT"

# 根据系统类型更新 grub 配置
if command -v update-grub >/dev/null 2>&1; then
  update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
  CFG_PATH=""
  if [[ -f /boot/grub/grub.cfg ]]; then
    CFG_PATH="/boot/grub/grub.cfg"
  elif [[ -f /boot/grub2/grub.cfg ]]; then
    CFG_PATH="/boot/grub2/grub.cfg"
  fi
  if [[ -n "$CFG_PATH" ]]; then
    grub-mkconfig -o "$CFG_PATH"
  else
    echo -e "${YELLOW}[!] 找不到 grub.cfg 位置，请手动 grub-mkconfig${NC}"
  fi
else
  echo -e "${YELLOW}[!] 未找到 update-grub 或 grub-mkconfig，请手动更新 GRUB 配置${NC}"
fi

echo
echo -e "${GREEN}[+] GRUB 自动安装入口已写入：${GRUB_SCRIPT}${NC}"
echo -e "${GREEN}[+] debian-installer 内核与 initrd 已准备完成${NC}"
echo
echo -e "${YELLOW}现在只需重启（reboot），系统会从新的 GRUB 条目启动：${NC}"
echo -e "${YELLOW}  *** po0 Auto Install Debian 12 (DD ALL ${DISK}) via Tencent ***${NC}"
echo -e "${YELLOW}安装过程将全自动完成，结束后会自动重启。${NC}"
echo -e "${YELLOW}安装完成后，用以下命令登录（示例）：${NC}"
echo -e "${YELLOW}  ssh -p ${SSH_PORT} root@你的IP${NC}"
echo -e "${YELLOW}如忘记密码，可在商家 VNC 登录后查看 /root/initial_root_password.txt。${NC}"
echo
read -rp "是否立刻重启？(y/N): " RB
if [[ "$RB" == "y" || "$RB" == "Y" ]]; then
  reboot
else
  echo -e "${YELLOW}[!] 请稍后手动执行 reboot 完成重装流程${NC}"
fi
