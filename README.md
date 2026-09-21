├── .github/
│   └── workflows/
│       └── build.yml             # GitHub Actions 云端编译工作流
├── Package.swift                 # SwiftPM 工程配置
├── Info.plist                    # macOS App 元数据配置
└── Sources/
    ├── App.swift                 # App 入口
    ├── Models/
    │   └── BiliModels.swift      # 数据模型 (视频、画质、评论、用户信息)
    ├── Services/
    │   ├── CookieManager.swift   # Cookie 与大会员状态持久化
    │   ├── WbiSigner.swift       # B站最新 Wbi 接口签名算法
    │   └── BiliService.swift     # 接口层 (推荐/热门/稍后再看/收藏/详情/流媒体/评论)
    ├── Player/
    │   ├── VideoPlayerManager.swift # 播放引擎 (音视频同步/画质切换/音量记忆)
    │   └── CustomPlayerView.swift   # 原生播放器视图与自研悬浮控制条
    └── Views/
        ├── MainView.swift        # 根界面与视图导航
        ├── SidebarView.swift     # 侧边栏 (推荐/热门/稍后看/收藏/用户卡片)
        ├── VideoCardView.swift   # 视频流卡片组件
        ├── VideoGridView.swift   # 视频流网格瀑布流
        ├── VideoDetailView.swift # 详情页 (左侧播放+推荐，右侧评论)
        ├── CommentSectionView.swift # 评论区 (包含楼中楼对话)
        └── LoginView.swift       # 扫码登录与 Cookie 导入弹窗
