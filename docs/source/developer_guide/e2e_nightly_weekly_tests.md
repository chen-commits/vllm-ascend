# vLLM Ascend Nightly/Weekly E2E 用例编写与运行机制

本文面向需要新增或维护 `tests/e2e/nightly`、`tests/e2e/weekly` 用例的测试人员，说明这些用例如何被 GitHub Actions 触发、如何落到具体执行脚本，以及新增用例时应该选择哪种编写方式。

## 1. 整体执行链路

Nightly/Weekly E2E 的核心链路可以概括为：

```text
schedule/workflow_dispatch/PR command
  -> .github/workflows/schedule_*_test_*.yaml
  -> build nightly/weekly image
  -> reusable workflow
     -> _e2e_nightly_single_node.yaml
     -> _e2e_nightly_multi_node.yaml
     -> _e2e_nightly_single_node_models.yaml
  -> pytest 或 YAML-driven 测试脚本
  -> benchmark_results / Ascend logs artifacts
```

入口 workflow 主要在 `.github/workflows/` 下：

- `schedule_nightly_test_a2.yaml`: A2 nightly 入口，支持 `workflow_dispatch`，也支持 PR 通过 `nightly-test` label 和 `/nightly-pr ...` 评论触发部分用例。
- `schedule_nightly_test_a3.yaml`: A3 nightly 入口，支持 `workflow_dispatch`，通过 `test_cases` 输入控制跑全部或指定用例。
- `schedule_weekly_test_a2.yaml`: A2 weekly 入口。
- `schedule_weekly_test_a3.yaml`: A3 weekly 入口，当前保留了 schedule 配置示例，但定时触发被注释，主要通过 `workflow_dispatch` 手动触发。
- `_e2e_nightly_single_node.yaml`: 单节点 reusable workflow，既能跑普通 pytest，也能跑 YAML-driven 单节点模型用例。
- `_e2e_nightly_multi_node.yaml`: 多节点 reusable workflow，通过 Kubernetes LeaderWorkerSet 拉起多节点 pod，再在 pod 内运行多机测试脚本。
- `_e2e_nightly_single_node_models.yaml`: 模型精度类矩阵测试入口，通常由 `accuracy_groups_*.json` 生成 matrix。

入口 workflow 的 `matrix.test_config` 是新增用例时最常改的地方。每个 matrix item 通常包含：

- `name`: 用例名，也是 `test_cases` 精确过滤的名称。
- `os`: 单节点用例使用的 runner，例如 `linux-aarch64-a3-16`。
- `tests`: pytest-driven 用例路径。
- `config_file_path`: YAML-driven 用例配置文件名。
- `size`: 多节点用例需要的节点数。

## 2. 用例如何触发

### 2.1 手动触发

Nightly/Weekly workflow 都支持 `workflow_dispatch`。常用输入：

- `vllm_ascend_branch`: 待测分支，workflow 会基于该分支构建镜像，镜像 tag 中会把 `/` 替换为 `-`。
- `test_cases`: 待运行用例。填 `all` 时运行 matrix 中全部用例；填逗号分隔的用例名时只运行匹配项，例如 `deepseek-v3-2-w8a8,engine-func-tests`。
- `skip_build_image`: Nightly 中用于复用已有镜像，通常由命令触发链路传入。
- `vllm_ascend_ref`: PR 场景下指定待测 commit SHA。

入口 workflow 会把 `test_cases` 解析成过滤字符串：

```text
all
或
,case_a,case_b,
```

随后每个 matrix item 通过 `contains(filter, format(',{0},', matrix.test_config.name))` 判断是否执行。因此新增用例后，`name` 必须稳定、唯一，并且和触发命令中填写的名称一致。

### 2.2 PR 触发

`schedule_nightly_test_a2.yaml` 额外支持 PR 事件：

1. PR 打上 `nightly-test` label。
2. 在 PR 评论中添加 `/nightly-pr case_name_a case_name_b`。
3. 当 PR labeled 或 synchronize 时，workflow 读取最新 `/nightly-pr` 评论，生成过滤条件。
4. PR 触发时会 checkout PR head sha，并在测试容器中重新安装 `vllm-ascend`。

如果只评论 `/nightly-pr` 但不带用例名，workflow 会认为没有需要执行的用例并跳过。

### 2.3 /nightly 命令触发

仓库中还有 `/nightly` 命令链路：

- `slash_command_dispatch.yml` 识别 slash command。
- `pr_nightly_command.yml` 解析命令、校验权限、解析测试名。
- 通过 `gh workflow run schedule_nightly_test_a2.yaml` 或 `schedule_nightly_test_a3.yaml` 分发到 nightly workflow。

这条链路适合从 PR 评论中显式触发 nightly，而不是依赖 PR label/synchronize 自动触发。

## 3. 单节点 YAML-driven 用例

单节点 YAML-driven 是新增模型功能、性能、精度组合用例最常用的方式。

### 3.1 目录和入口

配置文件通常放在：

- Nightly: `tests/e2e/nightly/single_node/models/configs/`
- Weekly: `tests/e2e/weekly/single_node/configs/`

执行入口是：

```text
tests/e2e/nightly/single_node/models/scripts/test_single_node.py
```

配置解析器是：

```text
tests/e2e/nightly/single_node/models/scripts/single_node_config.py
```

在 `_e2e_nightly_single_node.yaml` 中，如果 matrix item 传入了 `config_file_path`，workflow 会设置：

```bash
CONFIG_YAML_PATH=<config_file_path>
CONFIG_BASE_PATH=<config_base_path>
BENCHMARK_JOB_NAME=<branch>-<name>
pytest -sv tests/e2e/nightly/single_node/models/scripts/test_single_node.py
```

如果没有显式传 `config_base_path`，默认读取 nightly 目录 `tests/e2e/nightly/single_node/models/configs`。Weekly workflow 会显式传入 `tests/e2e/weekly/single_node/configs/`。

### 3.2 YAML 基本结构

单节点 YAML 顶层必须包含 `test_cases`，每个 case 会变成一个 pytest parameter。常见字段：

- `name`: case 名称，pytest id 和结果展示会使用它。
- `model`: 模型名。
- `envs`: 启动服务时注入的环境变量。
- `server_cmd`: `vllm serve <model>` 后面的参数列表。
- `server_cmd_extra`: 追加到 `server_cmd` 后面的参数列表，适合复用公共命令并增加差异项。
- `special_dependencies`: 运行前临时安装的 Python 依赖版本。
- `prompts`: completion/chat 请求使用的 prompt。
- `api_keyword_args`: OpenAI API 请求参数，例如 `max_tokens`。
- `test_content`: 要执行的功能检查，默认是 `completion`。
- `benchmarks`: aisbench 性能或精度任务。
- `service_mode`: 默认 `openai`，也支持 `epd`。

示例骨架：

```yaml
_envs: &envs
  TASK_QUEUE_ENABLE: "1"
  PYTORCH_NPU_ALLOC_CONF: "expandable_segments:True"
  SERVER_PORT: "DEFAULT_PORT"

_server_cmd: &server_cmd
  - "--tensor-parallel-size"
  - "4"
  - "--port"
  - "$SERVER_PORT"
  - "--trust-remote-code"

test_cases:
  - name: "example-model-aclgraph"
    model: "org/example-model"
    envs:
      <<: *envs
    server_cmd: *server_cmd
    server_cmd_extra:
      - "--compilation-config"
      - '{"cudagraph_mode":"FULL_DECODE_ONLY"}'
    test_content:
      - "chat_completion"
    benchmarks:
      perf:
        case_type: performance
        dataset_path: vllm-ascend/GSM8K-in3500-bs400
        request_conf: vllm_api_stream_chat
        dataset_conf: gsm8k/gsm8k_gen_0_shot_cot_str_perf
        num_prompts: 304
        max_out_len: 1500
        batch_size: 76
        baseline: 1
        threshold: 0.97
```

### 3.3 test_content 支持什么

`test_single_node.py` 通过 `TEST_HANDLERS` 分发 `test_content`：

- `completion`: 调用 `/v1/completions`，检查响应非空。
- `chat_completion`: 调用 `/v1/chat/completions`。
- `image`: 发送多模态 image 请求。
- `check_rank0_process_count`: 检查 rank0 上只有一个 `vllm serve` 进程。
- `benchmark_comparisons`: 不直接发请求，用于 benchmark 结果之间的自定义比较。

如果要新增一种 YAML 可配置的检查能力，需要在 `TEST_HANDLERS` 中注册新的 handler。

### 3.4 benchmark 结果

`benchmarks` 中非空的条目会传给 `tools.aisbench.run_aisbench_cases`。执行完成后，脚本会在 `benchmark_results/` 下写 JSON，workflow 随后上传：

- OBS artifact: `nightly-test-benchmark-results-<name>-<timestamp>`
- GitHub artifact: `nightly-test-benchmark-results-<branch>-<name>-<timestamp>`

结果 JSON 会包含模型、硬件、dtype、特性、vLLM/vLLM Ascend 版本、serve 命令、环境变量以及每个 benchmark task 的指标和 pass/fail。

### 3.5 新增步骤

1. 在对应 config 目录新增 YAML。
2. 本地或 CI 环境确认 YAML 可被 `SingleNodeConfigLoader` 解析。
3. 在 `schedule_nightly_test_a2.yaml`、`schedule_nightly_test_a3.yaml` 或 weekly workflow 的 `single-node-tests`/`multi-card-tests` matrix 中添加 item。
4. 根据模型资源选择合适 runner，例如 A3 16 卡模型使用 `linux-aarch64-a3-16`。
5. 使用 workflow_dispatch 的 `test_cases=<name>` 单独验证。

## 4. 多节点 YAML-driven 用例

多节点用例用于跨节点 DP、EP、disaggregated prefill、external DP 等场景。入口 workflow 统一是 `_e2e_nightly_multi_node.yaml`。

### 4.1 目录和分类

Nightly 多节点配置一般在：

- Internal DP: `tests/e2e/nightly/multi_node/internal_dp/config/`
- External DP: `tests/e2e/nightly/multi_node/external_dp/config/`

Weekly 多节点配置一般在：

- `tests/e2e/weekly/multi_node/internal_dp/config/`
- `tests/e2e/weekly/multi_node/external_dp/config/`

`_e2e_nightly_multi_node.yaml` 会根据 matrix 中传入的 `config_file_path` 和可选 `config_base_path` 把配置文件路径传给 pod。Weekly workflow 会显式设置 weekly 的 `config_base_path`。

### 4.2 Workflow 如何拉起多机环境

多节点 workflow 本身运行在控制节点容器中，不直接占用 NPU。它主要做这些事：

1. 解码 `KUBECONFIG_B64`。
2. 生成唯一的 `LWS_NAME`。
3. 使用 `tests/e2e/nightly/multi_node/scripts/lws.yaml.jinja2` 渲染 LeaderWorkerSet。
4. 按 `size` 拉起 leader 和 worker pod。
5. 等待所有 pod running/ready。
6. 跟随 leader pod 日志，如果日志里出现 `FAIL_TAG_<config_file_path>` 则判失败。
7. 从 PVC 收集 benchmark results、Ascend plog、pod stdout。
8. 删除 LWS 资源并上传 artifacts。

A3 默认每节点 16 NPU，A2 默认每节点 8 NPU。`size` 表示本用例需要几个节点。

### 4.3 Internal DP 配置

Internal DP 的执行脚本是：

```text
tests/e2e/nightly/multi_node/internal_dp/scripts/test_multi_node.py
```

配置解析器是：

```text
tests/e2e/nightly/multi_node/internal_dp/scripts/multi_node_config.py
```

YAML 必填字段：

- `model`
- `deployment`
- `num_nodes`
- `npu_per_node`
- `benchmarks`

`deployment` 的长度必须等于 `num_nodes`。每个 deployment 至少包含：

- `envs`: 当前节点环境变量。
- `server_cmd`: 当前节点启动命令。

脚本会解析当前 pod 在集群中的节点序号，自动注入：

- `HCCL_IF_IP`
- `HCCL_SOCKET_IFNAME`
- `GLOO_SOCKET_IFNAME`
- `TP_SOCKET_IFNAME`
- `LOCAL_IP`
- `NIC_NAME`
- `MASTER_IP`

常用占位符：

- `$LOCAL_IP`: 当前节点 IP。
- `$MASTER_IP`: master 节点 IP。
- `$SERVER_PORT`: 服务端口。

非 master 节点通常使用 `--headless`。master 节点负责跑 aisbench，其他节点通过 health check 等待退出。

### 4.4 External DP 配置

External DP 的执行脚本是：

```text
tests/e2e/nightly/multi_node/external_dp/scripts/test_external_dp.py
```

配置解析器是：

```text
tests/e2e/nightly/multi_node/external_dp/scripts/external_dp_config.py
```

YAML 必填字段：

- `model`
- `num_nodes`
- `npu_per_node`
- `routing`
- `config`
- `templates`
- `benchmarks`

External DP 会把每个节点展开为多个 rank，并按 `routing.type` 启动代理。当前支持的 routing 类型包括：

- `generic_dp`
- `disaggregated_prefill`

常用字段：

- `routing.groups`: 定义 prefiller/decoder 或其他路由分组。
- `config`: 每个节点的 DP 拓扑，例如 `dp_size`、`dp_size_local`、`dp_rank_start`、`tp_size`、`dp_address`。
- `templates`: 每个节点的环境变量和 `server_cmd_template`。

常用占位符：

- `${NODE_0_IP}`、`${NODE_1_IP}`: 指定节点 IP。
- `${LOCAL_IP}`: 当前节点 IP。
- `${MASTER_IP}`: master 节点 IP。
- `${LWS_WORKER_INDEX}`: LWS worker index。
- `${PORT}`、`${DP_SIZE}`、`${DP_RANK}`、`${TP_SIZE}` 等 rank 展开时的变量。

master 节点负责等待所有 rank ready、启动 proxy、执行 aisbench，并写 benchmark JSON；其他节点等待 master rank 停止。

### 4.5 新增步骤

1. 判断场景属于 internal DP 还是 external DP。
2. 在对应 config 目录新增 YAML。
3. 在 nightly/weekly workflow 的 `multi-node-tests` 或 `double-node-tests` matrix 中新增：

```yaml
- name: your-case-name
  config_file_path: Your-Config.yaml
  size: 2
```

4. 如果配置放在 weekly 目录，确认 workflow 传入了正确的 `config_base_path`。
5. 根据资源池设置 `max-parallel` 和 `size`，A3 资源有限时尤其要保守。
6. 用 `workflow_dispatch` + `test_cases=your-case-name` 单独验证。

## 5. Pytest-driven 用例：engine_func_test_robot

`tests/e2e/weekly/single_node/engine_func_test_robot` 是另一类用例：它不是通过 YAML 描述模型启动和 benchmark，而是用 pytest 直接写 OpenAI API 功能、参数边界和异常行为。

### 5.1 目录结构

```text
tests/e2e/weekly/single_node/engine_func_test_robot/
  conftest.py
  tests/
    top_k/
    top_p/
    temperature/
    tool_choice/
    ...
  utility/
    http_client.py
    request_helper.py
    assertion.py
```

在 workflow 中，它作为 pytest-driven 用例接入：

```yaml
- name: engine-func-tests
  os: linux-aarch64-a3-4
  tests: tests/e2e/weekly/single_node/engine_func_test_robot
```

或 A2：

```yaml
- name: mayi-cases
  os: linux-aarch64-a2b3-8
  tests: tests/e2e/weekly/single_node/engine_func_test_robot
```

`_e2e_nightly_single_node.yaml` 检测到 `tests` 非空后会执行：

```bash
pytest -sv "${tests}" \
  --ignore=tests/e2e/nightly/single_node/ops/singlecard_ops/test_fused_moe.py
```

### 5.2 Fixture 如何工作

`conftest.py` 中的 `api_client` 是 session 级 fixture：

1. 使用 `RemoteOpenAIServer` 启动模型服务。
2. 当前默认模型是 `Qwen/Qwen3-VL-30B-A3B-Instruct`。
3. 默认端口是 `8000`。
4. `server_args` 中配置 TP、EP、多模态限制、tool parser 等服务参数。
5. yield 一个 `HTTPClient(base_url=server.url_root)` 给所有测试使用。

也就是说，该目录下的测试文件只需要依赖 `api_client`，不需要自己启动/停止服务。

### 5.3 测试怎么写

典型测试流程：

1. 使用 `pytest.mark.parametrize` 覆盖 stream/non-stream、边界值、异常值。
2. 构造 OpenAI API 请求体。
3. 用 `request_helper.send_request(api_client, uri, request_body)` 发送请求。
4. 用 `utility.assertion` 中的断言函数检查状态码、finish_reason、错误码、流式响应格式等。

示例：

```python
import pytest

from tests.e2e.weekly.single_node.engine_func_test_robot.utility import assertion
from tests.e2e.weekly.single_node.engine_func_test_robot.utility import (
    request_helper as helper,
)


@pytest.mark.parametrize("stream", [False, True], ids=["non_stream", "stream"])
@pytest.mark.parametrize("top_k", [1, 10, 50], ids=["k1", "k10", "k50"])
def test_top_k_normal_values(api_client, stream, top_k):
    request_body = {
        "model": "auto",
        "messages": [{"role": "user", "content": "Say hello."}],
        "top_k": top_k,
        "stream": stream,
        "max_tokens": 100,
    }

    response = helper.send_request(api_client, "/v1/chat/completions", request_body)

    assertion.assert_chat_completion_success(response, stream)
```

### 5.4 适合写成 pytest 的场景

优先使用 `engine_func_test_robot` pytest 方式的场景：

- API 参数合法值、边界值、异常值覆盖。
- chat/completions、completions、tool choice、多模态请求等接口行为验证。
- 需要复杂断言，而不是只看 benchmark 指标。
- 多个 case 共用同一个服务配置，避免每个 case 都重新拉起模型。

不建议把大模型性能矩阵、长稳态压测、多节点拓扑写在这里；这些更适合 YAML-driven。

## 6. 如何选择编写方式

| 场景 | 推荐方式 | 原因 |
| --- | --- | --- |
| 单节点模型精度/性能验证 | single_node YAML | 启动参数、环境变量、benchmark 都可配置，容易进入 matrix |
| 单节点多个服务配置组合 | single_node YAML 的多个 `test_cases` | 一个 YAML 可复用 anchors，并由 pytest parameter 展开 |
| 多节点 internal DP/EP | multi_node internal YAML | 支持每节点 server_cmd 和自动注入分布式环境变量 |
| 多节点 external DP / PD | multi_node external YAML | 支持 rank 展开、proxy routing、prefill/decode 分组 |
| OpenAI API 参数功能测试 | engine_func_test_robot pytest | 断言灵活，复用 session 级服务 |
| 一次性验证某个 Python 逻辑 | 普通 pytest path | 直接通过 `tests` 字段接入 reusable workflow |

## 7. 新增用例 Checklist

- `name` 唯一且稳定，便于 `test_cases` 精确触发。
- runner 卡数和模型 TP/DP/PP 配置匹配。
- YAML 中端口优先使用 `DEFAULT_PORT` 或变量占位，避免并发冲突。
- 新环境变量如果属于 vLLM Ascend 行为开关，应先确认是否已在 `vllm_ascend/envs.py` 集中定义。
- benchmark 的 `baseline`、`threshold` 有明确含义，精度类和性能类不要混用判断标准。
- 多节点 `num_nodes`、`deployment/config/templates` 长度和 workflow matrix 的 `size` 保持一致。
- Weekly 配置要确认 workflow 传了正确的 `config_base_path`，否则会默认去 nightly 目录找配置。
- PR 或手动触发时先用 `test_cases=<name>` 跑单个用例，再扩大到 `all`。
- 需要保留排障信息时，关注 workflow 上传的 Ascend logs、pod stdout 和 benchmark artifacts。

## 8. 常见问题

### 为什么我的 YAML 找不到？

检查 workflow 是否传了正确的 `config_base_path`。单节点 YAML 默认路径是 `tests/e2e/nightly/single_node/models/configs`；weekly 单节点配置需要显式传 `tests/e2e/weekly/single_node/configs/`。

### 为什么手动指定 test_cases 没跑？

检查 `test_cases` 中填写的是 matrix item 的 `name`，不是 YAML 内部 `test_cases[].name`。过滤逻辑匹配的是 workflow matrix 的 `matrix.test_config.name`。

### 为什么 pytest-driven 和 YAML-driven 不能混在一个 matrix item 里？

`_e2e_nightly_single_node.yaml` 同时支持 `tests` 和 `config_file_path`，但语义不同。实际新增时建议一个 matrix item 只表达一种用例入口，避免排查时难以区分失败来自普通 pytest 还是 YAML driver。

### benchmark JSON 为什么没有生成？

只有 YAML-driven 且配置了非空 `benchmarks` 的用例才会生成 benchmark JSON。纯 pytest-driven 用例默认不会生成该类结果。

### 多节点失败后看哪里？

优先看 GitHub Actions 中 leader pod 的日志；其次下载 Ascend logs artifact。多节点 workflow 会收集每个 pod 的 stdout、Ascend plog，以及 external DP 的 rank 日志归档。
