#!/bin/bash
# 闪码发送器一键启动:在脚本所在目录起 http 服务并打开浏览器
# 用法:双击本文件(可随文件夹整体 copy 到任何 Mac),或 ./启动发送器.command
# 局域网其他设备访问 http://<下面打印的IP>:8000 (读剪贴板仅 localhost 可用)

cd "$(dirname "$0")" || exit 1

PORT=8000
# 端口被占就换一个,避免 "Address already in use"
while lsof -i :"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  PORT=$((PORT + 1))
done

IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo "本机")
echo "=========================================="
echo "  本机访问:  http://localhost:$PORT"
echo "  局域网访问: http://$IP:$PORT"
echo "  Ctrl+C 停止"
echo "=========================================="

# 仅 localhost 时自动开浏览器;远程登录场景(ssh)不弹
if [ -z "$SSH_CLIENT" ]; then
  open "http://localhost:$PORT"
fi

exec python3 -m http.server "$PORT"
