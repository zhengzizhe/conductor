#!/usr/bin/env bash
# 一次性创建一个稳定的自签名「代码签名」证书并导入登录钥匙串。
#
# 为什么需要它：macOS 的 TCC 权限（访问 桌面/文稿/下载 文件夹、完全磁盘访问、通知…）
# 是按 app 的"代码签名身份"记账的。make-app.sh 原来用 ad-hoc 签名（codesign --sign -），
# 没有稳定身份——每次重编译二进制 cdhash 都变，系统就当成一个新 app，把之前的授权全部
# 作废，于是"授权过了还反复弹框"。用一个固定的自签名身份签名后，身份不再变化，授权一次
# 即长期有效（包括在系统设置里给的「完全磁盘访问」）。
#
# 用法：Scripts/make-dev-cert.sh    然后重新跑 Scripts/make-app.sh 打包。
# 过程中可能弹一次系统对话框要登录密码（写入钥匙串的信任设置），属正常，仅此一次。
set -euo pipefail

IDENTITY="${CONDUCTOR_SIGN_IDENTITY:-Conductor Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "✅ 签名身份「${IDENTITY}」已存在，无需重复创建。"
  echo "   直接运行 Scripts/make-app.sh 即可。"
  exit 0
fi

echo "==> 生成自签名代码签名证书「${IDENTITY}」"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# openssl 生成自签名证书：必须带 codeSigning 扩展用途，codesign / find-identity 才认。
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = ${IDENTITY}
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:conductor -name "$IDENTITY" >/dev/null 2>&1

echo "==> 导入登录钥匙串（授权 /usr/bin/codesign 使用）"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P conductor -T /usr/bin/codesign >/dev/null

echo "==> 信任为代码签名证书（可能弹一次登录密码框）"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 || \
  echo "   （信任设置失败或被取消；如随后 make-app.sh 仍退回 ad-hoc，请改用钥匙串 GUI 法，见脚本注释末尾。）"

# 自检：确认 find-identity 能列出它（make-app.sh 用同样方式判断）。
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "✅ 完成。签名身份「${IDENTITY}」已就绪。"
  echo "   下一步：Scripts/make-app.sh 重新打包，再去"
  echo "   系统设置 › 隐私与安全性 › 完全磁盘访问 → 加入 Conductor.app（授权一次即永久）。"
else
  echo "❌ 身份未能注册为有效的代码签名标识。"
  echo "   请改用钥匙串 GUI 法："
  echo "     钥匙串访问 › 菜单「证书助理」› 创建证书 →"
  echo "     名称填「${IDENTITY}」、身份类型「自签名根」、证书类型「代码签名」，创建即可。"
  exit 1
fi
