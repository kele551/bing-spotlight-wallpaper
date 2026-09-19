# -*- coding: utf-8 -*-
"""彻底重建 Windows 图标缓存。

比单纯删文件多做三件事, 缺一件就刷不干净:
  1. 结束 explorer 并**等它真的死掉** (没死透就删, 它退出时又把旧的写回去)
  2. 删 %LOCALAPPDATA%\\Microsoft\\Windows\\Explorer 下的 iconcache_* / thumbcache_*
     以及老位置 %LOCALAPPDATA%\\IconCache.db
  3. 起来之后广播 WM_SETTINGCHANGE("ShellIcons") + SHChangeNotify(ASSOCCHANGED),
     强制 shell 里那张内存图标表失效
"""
import ctypes
import glob
import os
import subprocess
import sys
import time
from ctypes import wintypes

sys.stdout.reconfigure(encoding='utf-8')

LOCAL = os.environ.get('LOCALAPPDATA', os.path.expanduser('~'))
EXPL_DIR = os.path.join(LOCAL, r'Microsoft\Windows\Explorer')
PS = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'),
                  r'System32\WindowsPowerShell\v1.0\powershell.exe')


def say(*a):
    print(*a, flush=True)


def explorer_pids():
    r = subprocess.run(['tasklist', '/fo', 'csv', '/nh', '/fi', 'imagename eq explorer.exe'],
                       capture_output=True)
    out = r.stdout.decode('gbk', errors='replace')
    pids = []
    for line in out.splitlines():
        parts = [x.strip('"') for x in line.split(',')]
        if len(parts) >= 2 and parts[0].lower() == 'explorer.exe':
            try:
                pids.append(int(parts[1]))
            except ValueError:
                pass
    return pids


def kill_explorer():
    say('[1/4] 结束资源管理器...')
    before = explorer_pids()
    say('      当前 explorer 进程:', before or '无')
    subprocess.run(['taskkill', '/f', '/im', 'explorer.exe'],
                   capture_output=True)
    for _ in range(30):          # 最多等 15 秒
        time.sleep(0.5)
        if not explorer_pids():
            say('      已完全退出')
            return True
    say('      15 秒后仍在跑:', explorer_pids())
    return False


def delete_caches():
    say('[2/4] 删除缓存文件...')
    pats = [os.path.join(EXPL_DIR, 'iconcache_*.db'),
            os.path.join(EXPL_DIR, 'thumbcache_*.db'),
            os.path.join(LOCAL, 'IconCache.db')]
    total = ok = 0
    failed = []
    for pat in pats:
        for p in glob.glob(pat):
            total += 1
            # explorer 还活着的文件删不掉, 用 cmd del 也白搭, 所以先记着
            try:
                os.remove(p)
                ok += 1
            except Exception:
                # 退路: 交给 cmd
                r = subprocess.run(['cmd', '/c', 'del', '/f', '/a', p],
                                   capture_output=True)
                if not os.path.exists(p):
                    ok += 1
                else:
                    failed.append(os.path.basename(p))
    say('      共 %d 个, 删掉 %d 个' % (total, ok))
    if failed:
        say('      【没删掉】', ', '.join(failed))
    return failed


def notify_shell():
    say('[3/4] 通知 shell 丢弃内存里的图标表...')
    try:
        shell32 = ctypes.windll.shell32
        user32 = ctypes.windll.user32
        SHCNE_ASSOCCHANGED = 0x08000000
        SHCNF_IDLIST = 0x0000
        shell32.SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, None, None)
        # WM_SETTINGCHANGE, wParam=SPI_SETICONS(0x0058), lParam="ShellIcons"
        HWND_BROADCAST = 0xFFFF
        WM_SETTINGCHANGE = 0x001A
        SPI_SETICONS = 0x0058
        SMTO_ABORTIFHUNG = 0x0002
        res = wintypes.DWORD()
        user32.SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE,
                                   SPI_SETICONS, ctypes.c_wchar_p('ShellIcons'),
                                   SMTO_ABORTIFHUNG, 3000, ctypes.byref(res))
        say('      已广播 (结果 %s)' % res.value)
    except Exception as ex:
        say('      失败:', ex)


def start_explorer():
    say('[4/4] 重新启动资源管理器...')
    subprocess.Popen(['explorer.exe'], shell=False)
    for _ in range(20):
        time.sleep(0.5)
        if explorer_pids():
            say('      已启动, PID', explorer_pids())
            return True
    say('      没起来!')
    return False


def main():
    say('=' * 56)
    say('彻底重建图标缓存')
    say('=' * 56)
    kill_explorer()
    failed = delete_caches()
    notify_shell()
    start_explorer()
    say('')
    say('完成。删不掉的: %s' % (', '.join(failed) if failed else '无'))


main()
