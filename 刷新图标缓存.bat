@echo off
chcp 65001 >nul
title 微软壁纸助手 - 重建 Windows 图标缓存
echo.
echo   ============================================================
echo    重建 Windows 图标缓存
echo    桌面会闪一下, 打开的文件夹窗口会关掉, 不会丢任何文件
echo   ============================================================
echo.

rem ---------- 1. 结束资源管理器, 并且等它真的死掉 ----------
taskkill /f /im explorer.exe >nul 2>&1
set TRY=0
:WAIT
set /a TRY+=1
tasklist /fi "imagename eq explorer.exe" 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 goto KILLED
if %TRY% GEQ 30 goto STILL
timeout /t 1 /nobreak >nul
goto WAIT

:KILLED
echo   [1/3] 资源管理器已退出

rem ---------- 2. 删缓存 ----------
set ED=%LOCALAPPDATA%\Microsoft\Windows\Explorer
for %%F in (16 32 48 96 256 768 1280 1920 2560 idx sr exif wide custom_stream wide_alternate) do (
  del /f /a /q "%ED%\iconcache_%%F.db"  >nul 2>&1
  del /f /a /q "%ED%\thumbcache_%%F.db" >nul 2>&1
)
del /f /a /q "%LOCALAPPDATA%\IconCache.db" >nul 2>&1
echo   [2/3] 缓存文件已删除

rem ---------- 3. 校验: 索引文件必须真的没了 ----------
if exist "%ED%\iconcache_idx.db" (
  echo         [注意] iconcache_idx.db 还在, 图标可能还是旧的
) else (
  echo         索引文件已清干净
)
if exist "%ED%\thumbcache_idx.db" (
  echo         [注意] thumbcache_idx.db 还在
) else (
  echo         缩略图索引已清干净
)

rem ---------- 4. 系统自带的清缓存命令 ----------
if exist "%SystemRoot%\System32\ie4uinit.exe" (
  "%SystemRoot%\System32\ie4uinit.exe" -ClearIconCache >nul 2>&1
)

rem ---------- 5. 拉起来 ----------
start "" explorer.exe
echo   [3/3] 资源管理器已重启
echo.
echo   ------------------------------------------------------------
echo   好了。现在去看那个文件夹, 图标应该是新的。
echo   如果还是旧的: 注销一次再登录 (或重启电脑), 这是最彻底的。
echo   ------------------------------------------------------------
echo.
timeout /t 5 /nobreak >nul
goto :EOF

:STILL
echo   [失败] 资源管理器关不掉, 缓存删不动。
echo          请手动: 注销再登录, 或重启电脑。
echo.
timeout /t 5 /nobreak >nul
