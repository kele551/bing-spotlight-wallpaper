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
    同目录下的  微软壁纸助手.exe   -- 双击即用, 不安装, 不写注册表。
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
APP_NAME = '微软壁纸助手'
PAYLOAD_FILES = ['core.ps1', 'menu.ps1', '使用说明.txt', '微软壁纸助手.ico']
ICON = '微软壁纸助手.ico'


def main():
    missing = [f for f in PAYLOAD_FILES + ['launcher.py'] if not os.path.isfile(os.path.join(HERE, f))]
    if missing:
        print('缺文件, 没法打包: ' + ', '.join(missing))
        return 1

    work = tempfile.mkdtemp(prefix='mwa-build-')
    try:
        payload = os.path.join(work, 'payload')
        os.makedirs(payload, exist_ok=True)
        for f in PAYLOAD_FILES:
            shutil.copy2(os.path.join(HERE, f), os.path.join(payload, f))
        shutil.copy2(os.path.join(HERE, 'launcher.py'), os.path.join(work, 'launcher.py'))

        cmd = [
            sys.executable, '-m', 'PyInstaller',
            '--noconfirm', '--onefile', '--windowed',
            '--icon', os.path.join(HERE, ICON),
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
        dst = os.path.join(HERE, APP_NAME + '.exe')
        shutil.copy2(out, dst)
        print('')
        print('好了: ' + dst)
        print('大小: {:.1f} MB'.format(os.path.getsize(dst) / 1024.0 / 1024.0))
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
