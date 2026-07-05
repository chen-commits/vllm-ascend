## nightly和weekly用例

yaml-driven：
test_single_node.py -> aisbench.py -> AisbenchRunner -> init__ -> _run_aisbench_task -> yaml文件
multi_node同理

pytest-driven：
pytest -sv test_dir
里面写上pytest相关内容

本地跑通用例：guxin的两个文档

TODO：贴上pytest和yaml的图片




## CI调试
### workflows

workflows -> jobs -> steps
pytest和yaml-driven配置写在里面
走到_e2e_nightly_single_node.yaml或者_e2e_nightly_multi_node.yaml里面


/nightly-pr xxx和nightly-test label的逻辑被删掉了，等重构
或者参考：https://github.com/vllm-project/vllm-ascend/pull/10919

/nightly xxx触发已经存在的用例

TODO：下载日志
summary里贴一张截图

### 下载数据集
model_dataset_list.json
黑色的标签


## 一些注意点
### 精度
aime2025, gsm8k-lite阈值放到10
gpqa放到5

### 提交代码时，DCO
git commit -sm 
pycharm勾选