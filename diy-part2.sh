#!/bin/bash
# ==============================================================================
# DIY Part 2: 在执行 make 之前执行 (补丁注入、系统菜单纯化、服务菜单排序与语法门禁)
# ==============================================================================

set -e

echo "=================================================="
echo "--> 执行 DIY Part 2: 注入底层补丁与定制配置..."
echo "=================================================="

# 1. 确保版本号对齐为 25.12.2，保证与官方发布源及 distfeeds 完全兼容
if [ -f "include/version.mk" ]; then
  sed -i -E "s/25\.12-SNAPSHOT/25.12.2/g" include/version.mk 2>/dev/null || true
fi

# 2. 强化 include/scan.mk 扫描缓存覆盖，强制使用 mv -f 防止特定环境下终端提示卡死
if [ -f "include/scan.mk" ]; then
  sed -i -E 's/\bmv[[:space:]]+(\$\(TMP_DIR\)\/\.\$\(SCAN_TARGET\)\.tmp)/mv -f \1/g' include/scan.mk 2>/dev/null || true
fi

# 2.1 彻底剔除 official feeds 中可能残留的旧版 v2ray-geodata，防止软链接冲突或覆盖
rm -rf feeds/packages/net/v2ray-geodata package/feeds/packages/v2ray-geodata 2>/dev/null || true

# 3. 幂等适配 include/bpf.mk：自动探测系统 Clang/LLVM BPF 路径（优先检索 /usr/bin 与 /usr/lib/llvm-*/bin）
if [ -f "include/bpf.mk" ]; then
  if ! grep -q 'LLVM_PATH:=$(or $(shell for path in /usr/bin' include/bpf.mk 2>/dev/null; then
    sed -i '/CLANG:=\$(LLVM_PATH)\/clang/i \
  ifeq ($(LLVM_PATH),/invalid)\
    LLVM_PATH:=$(or $(shell for path in /usr/bin /usr/lib/llvm-18/bin /usr/lib/llvm-*/bin /usr/local/bin; do \\\
      test -x $$path/clang \&\& test -x $$path/llc \&\& test -x $$path/llvm-dis \&\& \\\
      test -x $$path/opt \&\& test -x $$path/llvm-strip \&\& { echo $$path; break; }; \\\
    done),/invalid)\
  endif' include/bpf.mk 2>/dev/null || true
  fi
fi

# 3.1 修复 daed / dae 源码硬编码 go >= 1.27.0 导致与系统官方内置 go 1.26 工具链冲突
python3 -c '
import os
targets = [
    ("openwrt-daede/daed/Makefile", "DAED_BUILD_DIR"),
    ("openwrt-daede/dae/Makefile", "DAE_BUILD_DIR")
]
for rel_path, bdir in targets:
    for base in ["package/custom-apps", "custom-apps", "package/feeds/custom", "feeds/custom"]:
        mf = os.path.join(base, rel_path)
        if os.path.exists(mf):
            try:
                with open(mf, "r", encoding="utf-8") as f:
                    content = f.read()
                target_marker = "\t$(TAR) --strip-components=1"
                hook = f"\tfind $({bdir}) -type f -name \"go.mod\" -exec sed -i -E '\''s/^go 1\\.[0-9]+(\\.[0-9]+)?/go 1.26/g; /^toolchain /d'\'' {{}} +"
                if target_marker in content and hook not in content:
                    lines = content.splitlines(True)
                    new_lines = []
                    for line in lines:
                        new_lines.append(line)
                        if line.startswith(target_marker):
                            new_lines.append(hook + "\n")
                    with open(mf, "w", encoding="utf-8") as f:
                        f.writelines(new_lines)
                    print(f"[+] 成功为 {mf} 注入 Go 1.26 自动兼容补丁")
            except Exception as e:
                print(f"[!] 注入 {mf} 补丁异常: {e}")
' 2>/dev/null || true

# 4. 修复 luci-app-daede 与 luci-app-honk 在线热更新脚本，适配带 @tag 仓库标签的 apk 依赖约束
for upd_sh in package/custom-apps/openwrt-daede/luci-app-daede/root/usr/share/luci-app-daede/update-pkg.sh \
              package/custom-apps/openwrt-honk/luci-app-honk/root/usr/share/luci-app-honk/update-pkg.sh; do
  if [ -f "$upd_sh" ]; then
    sed -i 's/constraint="\$PKG=\$ver"/tag=$(grep -E "^${PKG}@" \/etc\/apk\/world 2>\/dev\/null | head -1 | cut -d"@" -f2); if [ -n "$tag" ]; then constraint="${PKG}@${tag}=${ver}"; else constraint="${PKG}=${ver}"; fi/' "$upd_sh" 2>/dev/null || true
  fi
done

# 5. 修复 luci-app-honk 后台维护任务调用 nohup 导致导出备份失败 (OpenWrt busybox 环境无 nohup 命令)
honk_rpcd="package/custom-apps/openwrt-honk/luci-app-honk/root/usr/libexec/rpcd/honk"
if [ -f "$honk_rpcd" ]; then
  sed -i 's/nohup \"\$JOB_RUNNER\"/\"\$JOB_RUNNER\"/g' "$honk_rpcd" 2>/dev/null || true
fi

# 6. 修复 upstream feeds 中 sms-tool-js 的 JSON 尾随逗号语法错误
sms_json="feeds/luci/applications/luci-app-sms-tool-js/root/usr/share/luci/menu.d/luci-app-sms-tool-js.json"
if [ -f "$sms_json" ]; then
  python3 -c "
import re
p = '$sms_json'
try:
    with open(p, 'r', encoding='utf-8') as f:
        text = f.read()
    fixed = re.sub(r'\},(\s*\}\s*)$', r'}\1', text)
    if fixed != text:
        with open(p, 'w', encoding='utf-8') as f:
            f.write(fixed)
except Exception:
    pass
" 2>/dev/null || true
fi

# 7. 导入自定义 files 覆盖层
if [ -d "$GITHUB_WORKSPACE/files" ]; then
  echo "--> 正在合并 files/ 文件覆盖层..."
  mkdir -p files
  cp -r "$GITHUB_WORKSPACE/files/"* files/ 2>/dev/null || true
fi

# 8. 动态从 feeds 提取原版 luci-mod-system.json，剔除 plugins 并写入 files/ 覆盖层
orig_mod_json=$(find feeds/ -type f -path "*/luci-mod-system/root/usr/share/luci/menu.d/luci-mod-system.json" 2>/dev/null | head -n 1)
if [ -n "$orig_mod_json" ] && [ -f "$orig_mod_json" ]; then
  echo "--> 动态生成 files/ 纯净系统菜单 (移除插件，保留软件包)..."
  mkdir -p files/usr/share/luci/menu.d/
  python3 -c "
import json, sys
src = sys.argv[1]
dst = sys.argv[2]
try:
    with open(src, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if 'admin/system/plugins' in data:
        del data['admin/system/plugins']
    output = json.dumps(data, indent=4, ensure_ascii=False)
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(output)
except Exception as e:
    print(f'[WARN] 生成 files/luci-mod-system.json 告警: {e}', file=sys.stderr)
" "$orig_mod_json" "files/usr/share/luci/menu.d/luci-mod-system.json" || true
fi

# 9. 根据 .config 动态校验是否引入 @honk apk 源
if grep -q "CONFIG_PACKAGE_luci-app-honk=y" .config 2>/dev/null || grep -q "CONFIG_PACKAGE_honk=y" .config 2>/dev/null; then
  mkdir -p files/etc/apk/repositories.d/
  touch files/etc/apk/repositories.d/customfeeds.list
  if ! grep -q "@honk" files/etc/apk/repositories.d/customfeeds.list 2>/dev/null; then
    echo "@honk https://down.dllkids.xyz/openwrt-feed/25.12/x86_64/packages.adb" >> files/etc/apk/repositories.d/customfeeds.list
  fi
fi


# 11. JSON 语法自检门禁
echo "--> 正在执行 JSON 语法自检门禁..."
python3 -c "
import json, os, sys

invalid = []
for root_dir in ['package', 'feeds', 'files']:
    if not os.path.exists(root_dir):
        continue
    for root, _, files in os.walk(root_dir):
        for f in files:
            if f.endswith('.json') and 'menu.d' in root:
                p = os.path.join(root, f)
                try:
                    with open(p, 'r', encoding='utf-8') as fp:
                        json.load(fp)
                except Exception as err:
                    invalid.append(f'{p}: {err}')

if invalid:
    for item in invalid:
        print(f'[ERROR] JSON 语法校验失败: {item}', file=sys.stderr)
    print('[ERROR] 发现损坏的 LuCI 菜单文件，已停止编译。', file=sys.stderr)
    raise SystemExit(1)
else:
    print('[OK] 所有 LuCI 菜单 JSON 格式严格通过校验！')
"

echo "--> DIY Part 2 执行成功！"
