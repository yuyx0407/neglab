# legacy/ —— 早期原型，保留作参考

这里的三个文件属于 NegLab 的第一版：Python + PySide6 的桌面程序。当前版本已经
换成 AppKit 原生的 `NegLab.app`（见仓库根目录），原因是这一版要求用户自己装
Python 和 PySide6，对一个「只想把胶卷转成正片」的人来说门槛太高。

保留它们的理由只有一个：**数学的 Python 参考实现**。`app/NegMath.m` 里的秩 1
分解、`negInvert`、`negNeutralResidual`，都是照着这里的 `neglab_pyside.py` 写并
逐位核对过的。将来若有人要在 Python 里复现同一套结果，看这份代码最快。

| 文件 | 是什么 |
|---|---|
| `neglab_pyside.py` | PySide6 界面 + 全部数学（`fit_gamma` / `invert` / `to_display` / `health`） |
| `demask.py` | 十四种去色罩方法的实现，用来做横向对比 |
| `build_app-pyinstaller.py` | 早期把 Python 版打成 .app 的脚本（成品 300 MB 上下，已弃用） |

**不要期待这里能跑起来。** 需要 `pip install PySide6 numpy opencv-python`，
而且路径与接口都可能与当前版本不一致。使用请用 `NegLab.app`。
