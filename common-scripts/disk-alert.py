#!/usr/bin/env python3
# 磁盘使用率检测，超过阈值发送钉钉告警
# 环境变量配置：DINGTALK_WEBHOOK, DISK_ALERT_THRESHOLD

import shutil
import requests
import json
import socket
import os

# 配置 - 优先从环境变量读取
DINGTALK_WEBHOOK = os.environ.get('DINGTALK_WEBHOOK', '')
THRESHOLD = int(os.environ.get('DISK_ALERT_THRESHOLD', '90'))  # 百分比
CHECK_PARTITIONS = ['/']  # 需要检查的挂载点

def get_disk_usage(path):
    total, used, free = shutil.disk_usage(path)
    return (used / total) * 100

def send_alert(partition, usage):
    if not DINGTALK_WEBHOOK:
        print("警告：未配置 DINGTALK_WEBHOOK 环境变量，跳过告警发送")
        return
    
    hostname = socket.gethostname()
    message = {
        "msgtype": "text",
        "text": {
            "content": f"[磁盘告警] 主机 {hostname} 的 {partition} 分区使用率已达到 {usage:.1f}%，超过阈值 {THRESHOLD}%"
        }
    }
    try:
        response = requests.post(DINGTALK_WEBHOOK, headers={"Content-Type": "application/json"}, data=json.dumps(message))
        print(f"告警发送状态：{response.status_code}")
    except Exception as e:
        print(f"发送告警失败：{e}")

def main():
    for partition in CHECK_PARTITIONS:
        usage = get_disk_usage(partition)
        if usage > THRESHOLD:
            send_alert(partition, usage)

if __name__ == "__main__":
    main()