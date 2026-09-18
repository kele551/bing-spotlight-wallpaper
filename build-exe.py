# -*- coding: utf-8 -*-
"""
一键打包: 把 launcher.py + core.ps1 + menu.ps1 + 使用说明.txt + 图标
打成一个单文件绿色 exe。

用法
----
    双击本文件, 或在命令行跑:  python build-exe.py

前置条件
--------
    Python 3.9 以上, 并且装过 pyinstaller:
        python -m pip install pyinstaller

产物
----
    同目录下两份 (内容一模一样, 只是名字不同):

      微软壁纸助手-vX.Y.Z.exe   -- 名字带版本号, 方便一眼看出是哪一版
      微软壁纸助手.exe          -- 固定名字, 用来部署;
                                  「开机自动换壁纸」的快捷方式指向这个名字,
                                  换了版本也不会断链。

    双击即用, 不安装, 不写注册表。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
APP_NAME = '微软壁纸助手'
PAYLOAD_FILES = ['core.ps1', 'menu.ps1', '使用说明.txt', '微软壁纸助手.ico']
ICON = '微软壁纸助手.ico'


def read_version():
    """版本号以 launcher.py 里的 VERSION 为唯一来源, 免得三处各写各的。"""
    src = os.path.join(HERE, 'launcher.py')
    with open(src, 'r', encoding='utf-8') as f:
        m = re.search(r"^VERSION\s*=\s*['\"]([^'\"]+)['\"]", f.read(), re.M)
    if not m:
        raise SystemExit('launcher.py 里找不到 VERSION, 没法确定版本号')
    return m.group(1)


def make_version_file(path, version):
    """给 exe 写一份 Windows 版本资源: 右键 - 属性 - 详细信息里能看到版本号。

    语言 0804 = 简体中文, 代码页 1200 = Unicode。
    """
    parts = [int(x) for x in re.findall(r'\d+', version)]
    while len(parts) < 4:
        parts.append(0)
    vtuple = '({})'.format(', '.join(str(p) for p in parts[:4]))
    text = """# UTF-8
VSVersionInfo(
  ffi=FixedFileInfo(
    filevers={vt}, prodvers={vt},
    mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)
  ),
  kids=[
    StringFileInfo([
      StringTable(
        '080404b0',
        [
          StringStruct('CompanyName', 'kele551'),
          StringStruct('FileDescription', '微软壁纸助手 - 必应每日一图 + Windows 聚焦'),
          StringStruct('FileVersion', '{v}'),
          StringStruct('InternalName', 'MSWallpaperAssistant'),
          StringStruct('LegalCopyright', 'MIT License'),
          StringStruct('OriginalFilename', '微软壁纸助手.exe'),
          StringStruct('ProductName', '微软壁纸助手'),
          StringStruct('ProductVersion', '{v}')
        ]
      )
    ]),
    VarFileInfo([VarStruct('Translation', [2052, 1200])])
  ]
)
""".format(vt=vtuple, v=version)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def main():
    missing = [f for f in PAYLOAD_FILES + ['launcher.py'] if not os.path.isfile(os.path.join(HERE, f))]
    if missing:
        print('缺文件, 没法打包: ' + ', '.join(missing))
        return 1

    version = read_version()
    print('版本号: ' + version)

    work = tempfile.mkdtemp(prefix='mwa-build-')
    try:
        payload = os.path.join(work, 'payload')
        os.makedirs(payload, exist_ok=True)
        for f in PAYLOAD_FILES:
            shutil.copy2(os.path.join(HERE, f), os.path.join(payload, f))
        shutil.copy2(os.path.join(HERE, 'launcher.py'), os.path.join(work, 'launcher.py'))

        vfile = os.path.join(work, 'file_version.txt')
        make_version_file(vfile, version)

        cmd = [
            sys.executable, '-m', 'PyInstaller',
            '--noconfirm', '--onefile', '--windowed',
            '--icon', os.path.join(HERE, ICON),
            '--version-file', vfile,
            '--add-data', 'payload;payload',
            '--name', APP_NAME,
            '--distpath', os.path.join(work, 'dist'),
            '--workpath', os.path.join(work, 'build'),
            '--specpath', work,
            'launcher.py',
        ]
        print('正在打包, 大概半分钟...')
        r = subprocess.run(cmd, cwd=work)
        if r.returncode != 0:
            print('打包失败。')
            return r.returncode

        out = os.path.join(work, 'dist', APP_NAME + '.exe')
        if not os.path.isfile(out):
            print('打包完了但没找到产物: ' + out)
            return 1
        # 两份: 一份名字带版本号(好认), 一份固定名字(部署用, 不打断已有快捷方式)
        outs = []
        plain = os.path.join(HERE, APP_NAME + '.exe')
        tagged = os.path.join(HERE, '{}-v{}.exe'.format(APP_NAME, version))
        for dst in (plain, tagged):
            shutil.copy2(out, dst)
            outs.append(dst)
        print('')
        for dst in outs:
            print('好了: ' + dst)
        print('大小: {:.1f} MB'.format(os.path.getsize(outs[0]) / 1024.0 / 1024.0))
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
