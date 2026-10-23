"""Observed labels offered as options, not issuer terms or bank integrations."""

BANKS = [
    {"id": code, "name": name}
    for code, name in [
        ("boc", "中国银行"),
        ("cmb", "招商银行"),
        ("icbc", "工商银行"),
        ("abc", "农业银行"),
        ("ccb", "建设银行"),
        ("bocom", "交通银行"),
        ("spdb", "浦发银行"),
        ("cgb", "广发银行"),
        ("psbc", "邮储银行"),
        ("rcc", "农信社"),
        ("pingan", "平安银行"),
    ]
]
PROVIDERS = [
    {"id": code, "name": name, "kind": kind}
    for kind, labels in [
        (
            "cash",
            [
                ("wechat", "微信"),
                ("lingqiantong", "微信零钱通"),
                ("alipay", "支付宝"),
                ("yuebao", "余额宝"),
                ("yulibao", "余利宝"),
                ("xiaohebao", "小荷包"),
                ("unionpay", "云闪付"),
                ("housing", "公积金"),
                ("qq", "QQ钱包"),
                ("jd", "京东金融"),
                ("medical", "医保"),
                ("ecny", "数字人民币"),
                ("huawei", "华为钱包"),
                ("pinduoduo", "多多钱包"),
                ("paypal", "Paypal"),
            ],
        ),
        (
            "credit_card",
            [
                ("credit_card", "信用卡"),
                ("huabei", "花呗"),
                ("jiebei", "借呗"),
                ("baitiao", "京东白条"),
                ("meituan", "美团月付"),
                ("douyin", "抖音月付"),
                ("fenfu", "微信分付"),
            ],
        ),
        (
            "prepaid",
            [
                ("phone", "话费"),
                ("utilities", "水电"),
                ("meal", "饭卡"),
                ("deposit", "押金"),
                ("transit", "公交卡"),
                ("membership", "会员卡"),
                ("fuel", "加油卡"),
                ("sinopec", "石化钱包"),
                ("apple", "Apple"),
            ],
        ),
        (
            "investment",
            [
                ("stock", "股票"),
                ("fund", "基金"),
                ("gold", "黄金"),
                ("forex", "外汇"),
                ("futures", "期货"),
                ("bond", "债券"),
                ("fixed_income", "固定收益"),
                ("crypto", "加密货币"),
            ],
        ),
    ]
    for code, name in labels
]
PROVIDER_KINDS = {row["id"]: row["kind"] for row in PROVIDERS}
BANK_IDS = {row["id"] for row in BANKS}
