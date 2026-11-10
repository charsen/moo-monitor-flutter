# TODOS

- [ ] 定向真机采集、离线重启补发、撤权及设备生命周期验证；未授权前不启动设备/E2E。
- [ ] 原生 Android/iOS 适配复用既有 SDK，明确双队列去重和身份后再接入；不在 Dart 捕获原生信号。
- [ ] AOT split-debug-info 符号还原、系统后台机会、Application Support 备份排除。
- [ ] 评估稳定安装身份的原生存储；不读取业务账号或硬件标识。
