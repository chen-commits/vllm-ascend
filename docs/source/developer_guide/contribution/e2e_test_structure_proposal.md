# E2E 测试目录重构分析与建议

## 1. 背景

当前 `tests/e2e/nightly` 和 `tests/e2e/weekly` 下的测试持续增长，测试内容、运行周期和资源拓扑同时体现在目录层级中，导致以下问题：

- 查找用例时需要先知道它属于 nightly 还是 weekly；
- 相同测试能力可能在两个周期目录中重复维护；
- `single_node` 和 `multi_node` 描述的是运行资源，而不是测试内容；
- 测试代码、模型配置、集群启动脚本和结果处理逻辑相互耦合；
- 调整目录会影响 CI、bisect、结果基线及 Python 导入路径。

截至本次盘点，nightly 和 weekly 目录共有 367 个已跟踪文件，其中包括：

- 131 个 `test_*.py` 文件；
- 191 个 YAML 配置文件；
- 17 组文件名相同的 YAML，部分同名文件内容不同；
- `.github`、`tests/e2e`、`tests/ut` 和 `tools` 中约 206 处相关路径或模块引用。

## 2. 重构目标

本次重构只改变测试资产的组织方式，不改变现有调度能力。

需要保留：

1. nightly 和 weekly 两种调度周期；
2. 单节点、2 节点和多节点三类资源调度方式；
3. A2、A3、A5、310P 等硬件及 runner 差异；
4. internal DP、external DP、PD 等部署模式；
5. nightly 和 weekly 各自独立的结果及 bisect 基线。

期望实现：

1. 目录回答“测试什么”；
2. CI 配置回答“何时运行、在哪里运行、需要多少资源”；
3. 测试入口回答“如何启动服务和执行断言”；
4. 不再通过文件路径推断运行周期或资源拓扑。

## 3. 建议的目标目录

现有 `pull_request` 目录依赖独立的 PR 调度和路径校验，建议本次保持不变。nightly 和 weekly 的测试资产合并到 `periodic`：

```text
tests/e2e/
├── pull_request/                 # PR 阶段测试，暂不调整
└── periodic/                     # 定期调度的 E2E 测试
    ├── models/                   # 模型精度、性能和模型配置
    │   ├── configs/
    │   └── test_model_benchmark.py
    ├── features/                 # 面向用户或系统能力的测试
    │   ├── pooling/
    │   ├── graph_mode/
    │   ├── speculative_decoding/
    │   ├── structured_output/
    │   └── distributed/          # DP、PD、跨节点通信等特性
    ├── ops/                      # 算子及算子组合测试
    └── common/                   # 通用启动器、集群工具、结果处理和 fixture
        ├── cluster/
        ├── runtime/
        └── reporting/
```

分类以测试的主要目的为准：

- 验证某个模型的精度或吞吐量，归入 `models`；
- 验证池化、图模式、推测解码、DP 或 PD 行为，归入 `features`；
- 验证单个算子或算子组合在 NPU 上的正确性，归入 `ops`；
- 被多个类别复用的启动、资源发现、日志及结果处理代码，归入 `common`。

目录中不再包含 `nightly`、`weekly`、`single_node` 或 `multi_node`。节点拓扑仍然可以出现在测试名称、fixture 参数或 CI 元数据中，但不作为顶层分类。

## 4. 调度与目录的边界

### 4.1 调度周期

继续保留：

- `.github/workflows/configs/nightly_config.yaml`；
- `.github/workflows/configs/weekly_config.yaml`；
- nightly 和 weekly 各自的定时触发及手动命令；
- 各自独立的 good table 和结果命名空间。

两个矩阵可以引用同一个测试文件。测试属于哪个周期，由矩阵是否选中它决定，而不是由它所在的目录决定。

### 4.2 资源拓扑

继续保留以下运行模式：

| 运行模式 | 含义 | 调度侧职责 |
| --- | --- | --- |
| `single_node` | 单节点运行 | 选择 runner、镜像和单机测试入口 |
| `double_node` | 固定 2 节点运行 | 申请两节点资源并传递节点信息 |
| `multi_node` | 节点数由用例指定 | 根据 `size` 创建集群并协调各节点 |

这些字段可以继续作为 CI 矩阵的分组，以便复用现有工作流。取消目录层级不等于取消这些调度概念。

### 4.3 DP 负载均衡模式

现有 `internal_dp` 和 `external_dp` 目录实际上区分的是 DP rank 的启动及请求负载均衡方式。为与 vLLM 的 internal、hybrid 和 external load balancing 概念对应，建议在调度配置中使用 `dp_load_balancing` 字段：

```yaml
a3:
  multi_node:
    test_config:
      - name: speculative-decoding-external-lb
        test: tests/e2e/periodic/features/speculative_decoding/test_accuracy.py
        size: 4
        npu_per_node: 16
        dp_load_balancing: external
        serving_topology: disaggregated_prefill
```

各字段分别表达：

- 外层 `single_node`、`double_node` 或 `multi_node`：选择资源调度方式；
- `size`：为 `multi_node` 指定具体节点数；`double_node` 固定为 2，通常不需要重复填写；
- `dp_load_balancing`：使用 internal、hybrid 或 external DP 负载均衡；
- `serving_topology`：普通服务、PD 分离等服务拓扑；
- `test`：最终执行的 pytest 文件或 node id。

当前嵌套矩阵中不应在条目内重复增加 `resource_mode`，否则外层分组和条目字段可能发生冲突。未来如果改成扁平矩阵，可以用 `resource_mode` 替代外层分组，但两种表达方式不应同时存在。

nightly 和 weekly 已经由矩阵文件本身表达，不需要在每个条目中重复保存调度周期。

同一个 pytest 可以由多个矩阵条目在不同模式下运行：

```yaml
a3:
  multi_node:
    test_config:
      - name: speculative-decoding-internal-lb
        test: tests/e2e/periodic/features/speculative_decoding/test_accuracy.py
        size: 4
        dp_load_balancing: internal

      - name: speculative-decoding-external-lb
        test: tests/e2e/periodic/features/speculative_decoding/test_accuracy.py
        size: 4
        dp_load_balancing: external
```

不建议在每个特性目录下重复建立 `internal_dp/` 和 `external_dp/`。例如 `speculative_decoding` 和 `structured_output` 的测试步骤与断言仍放在各自的特性目录中，不同负载均衡模式的公共启动实现集中放置：

```text
tests/e2e/periodic/
├── features/
│   ├── speculative_decoding/
│   └── structured_output/
└── common/
    └── data_parallel/
        ├── internal_lb.py
        ├── hybrid_lb.py
        └── external_lb.py
```

如果同一特性在两种模式下使用相同断言，由 fixture 根据 `dp_load_balancing` 选择 runtime。如果测试逻辑确实不同，可以在同一个特性目录下使用 `test_internal_load_balancing.py` 和 `test_external_load_balancing.py`。只有某种模式已经形成大量专属测试时，才在该特性内部增加局部子目录。

### 4.4 调度参数传递链路

`dp_load_balancing` 应以 nightly/weekly 矩阵为唯一权威来源。pytest marker 可以用于展示和筛选，但不能负责申请资源，因为 pytest 启动时集群已经创建完成。

参数按照以下链路传递：

```mermaid
flowchart LR
    A[nightly_config / weekly_config] -->|dp_load_balancing| B[Schedule workflow]
    B --> C[Reusable E2E workflow]
    C --> D[LeaderWorkerSet 环境变量]
    D --> E[run.sh]
    E -->|--dp-load-balancing| F[pytest]
    F --> G[DP runtime fixture]
```

可复用 workflow 增加字符串输入：

```yaml
on:
  workflow_call:
    inputs:
      dp_load_balancing:
        type: string
        required: false
        default: internal
```

LeaderWorkerSet 将其传给所有节点：

```yaml
env:
  - name: DP_LOAD_BALANCING
    value: "{{ dp_load_balancing }}"
```

`run.sh` 应先校验取值，再将它传给统一的 pytest 入口：

```bash
case "${DP_LOAD_BALANCING}" in
  internal|hybrid|external) ;;
  *) echo "Unsupported DP_LOAD_BALANCING: ${DP_LOAD_BALANCING}"; exit 2 ;;
esac

pytest -sv "${TEST_PATH}" \
  --dp-load-balancing "${DP_LOAD_BALANCING}"
```

pytest fixture 最终选择 `InternalLBServer`、`HybridLBServer` 或 `ExternalLBServer`。这些 runtime 封装节点角色、rank 进程、代理、健康检查和资源清理，具体特性测试只保留请求与断言。

迁移初期可以继续保留现有 `single_node`、`double_node`、`multi_node` 矩阵结构，只增加并透传 `dp_load_balancing`。后续再考虑统一矩阵 schema，避免一次改动同时重写目录和调度系统。

## 5. 多机用例是否可以直接使用 pytest

可以。现有多机流程最终已经在每个节点上执行 pytest；YAML 主要承担测试参数和节点启动参数的数据载体。

pytest 文件可以直接表达：

- 节点角色和服务启动参数；
- 服务健康检查；
- 请求及行为断言；
- 日志收集与资源清理；
- 按节点索引执行不同逻辑；
- 使用 `pytest.mark.parametrize` 复用少量参数组合。

但是 pytest 不负责申请机器。多机测试仍需要 CI 或集群编排层完成：

1. 根据矩阵中的 `size` 申请节点；
2. 在各节点设置节点索引、IP、主节点地址等环境信息；
3. 在所有节点启动同一个 pytest 入口；
4. 汇总状态、日志和测试结果；
5. 完成超时处理和资源回收。

因此需要区分两种 YAML：

- **测试数据 YAML**：描述模型、启动参数和 benchmark 参数，可以根据场景改为 pytest、fixture 或 Python 数据对象；
- **基础设施 YAML**：描述 LeaderWorkerSet、Pod、资源和挂载，仍需由 CI/集群系统保留。

建议采用混合方案：

- 特性测试优先直接写成 pytest，因为测试步骤和断言是核心；
- 模型精度和性能测试继续数据驱动，避免为大量相似参数复制 Python 文件；
- 通用的单机、多机启动能力封装成 fixture 或 helper，测试文件只保留场景配置与断言。

## 6. 当前主要阻碍

### 6.1 运行周期依赖目录名

结果后处理当前通过 `CONFIG_BASE_PATH` 是否包含 `weekly` 推断结果属于 nightly 还是 weekly。合并为 `periodic` 后，这种推断将失效。

处理方式：由 workflow 显式传入 `test_frequency=nightly|weekly`，结果处理只读取该字段，不读取目录名。

### 6.2 多机入口依赖配置路径

多机 `run.sh` 当前通过配置路径是否包含 `external_dp/config` 来选择 internal DP 或 external DP 入口。

处理方式：在矩阵中显式传入 `dp_load_balancing`，并由统一 pytest fixture 选择对应 runtime。路径只用于定位文件，不再决定运行行为。

### 6.3 同名 YAML 冲突

nightly 和 weekly 中存在 17 组同名 YAML，且部分同名文件内容不同。不能直接复制到同一个 `configs` 目录。

每组需要判断：

1. 内容相同：合并为一个配置，由两个周期共同引用；
2. 仅 benchmark 参数不同：提取公共配置，周期差异放到 CI 参数或配置变体中；
3. 语义确实不同：用模型、量化、硬件或场景信息明确命名。

不建议继续用 `_nightly`、`_weekly` 作为文件名差异，因为这会重新把调度周期写入测试资产。

### 6.4 固定路径引用较多

受影响范围包括：

- nightly 和 weekly 测试矩阵；
- 单节点及多节点可复用 workflow；
- `run.sh` 和 LeaderWorkerSet 模板；
- `tests/e2e/conftest.py` 及测试内部 Python 导入；
- `tools/bisect`；
- good table 更新脚本；
- 单元测试、开发文档和命令示例。

路径迁移必须使用全仓检索，并对每批改动做引用完整性检查。

### 6.5 历史基线包含测试路径

good table 和 bisect 使用 `soc + scene + test_path` 识别用例。路径改变后，新记录可能无法匹配旧记录。

短期可以在迁移时提供旧路径到新路径的映射。长期建议引入不依赖路径的稳定 `case_id`，例如：

```text
model.qwen3_235b.w8a8.performance
feature.external_lb.kv_transfer
op.triton.rms_norm
```

### 6.6 fixture 作用域可能变化

当前算子目录中的 `conftest.py` 会初始化 NPU/Triton 环境。移动目录时必须保持它只作用于 `ops`，避免影响模型或特性测试。

## 7. 建议的实施顺序

### 阶段一：解除路径与语义的耦合

1. 让结果处理显式读取 `test_frequency`；
2. 让多机启动显式读取 `dp_load_balancing` 并选择对应 runtime；
3. 为调度条目补充稳定的资源信息；
4. 为 good table 设计路径迁移方案或稳定 `case_id`。

该阶段先不移动测试文件，以便单独验证行为变化。

### 阶段二：建立 `periodic/common`

1. 移动通用结果处理代码；
2. 移动单机和多机公共 runtime；
3. 修正 Python 导入和 bisect 入口；
4. 为路径解析、周期标识和运行入口选择增加单元测试。

### 阶段三：迁移 `ops` 和 `features`

1. 先迁移依赖少、没有配置冲突的算子测试；
2. 保持算子专用 `conftest.py` 的作用域；
3. 将结构化输出、池化、图模式和推测解码等迁入 `features`；
4. 适合直接表达行为的多机特性改写为 pytest。

### 阶段四：迁移模型测试与配置

1. 逐组处理 17 个同名 YAML；
2. 合并公共模型配置；
3. 保留确有必要的参数变体；
4. 同步更新 nightly 和 weekly 矩阵引用。

### 阶段五：清理旧目录

1. 确认全仓不再引用旧路径；
2. 删除空的 `nightly` 和 `weekly` 测试目录；
3. 更新贡献指南和命令示例；
4. 验证定时任务、手动命令、结果上传和 bisect。

## 8. 验收标准

目录迁移完成后应满足：

- nightly 和 weekly 的用例集合与迁移前一致；
- 单节点、2 节点和多节点任务使用的资源数量与迁移前一致；
- internal DP、external DP 和 PD 使用正确的测试入口；
- pytest 能收集所有直接测试文件；
- 所有矩阵中的测试路径和配置路径都存在；
- nightly 和 weekly 的结果写入各自的结果空间；
- good table 和 bisect 可以识别迁移后的用例；
- 算子 fixture 不影响 `models` 和 `features`；
- 全仓不再依赖 `tests/e2e/nightly` 或 `tests/e2e/weekly` 的旧路径。

## 9. 结论

建议采用 `tests/e2e/periodic/{models,features,ops,common}` 作为目标结构，并暂时保持 `tests/e2e/pull_request` 不变。

nightly/weekly 和 single-node/double-node/multi-node 应继续存在于调度配置及运行元数据中。目录重构的核心是将“测试内容”与“运行方式”分离，而不是减少现有调度能力。

多机用例可以直接使用 pytest。对于行为型特性测试，pytest 更易表达步骤和断言；对于大量模型精度和性能组合，保留数据驱动配置更易维护。整个迁移应先解除路径耦合，再分批移动文件，以降低 CI 和历史基线同时失效的风险。

## 10. 工作量评估

### 10.1 估算前提

以下估算基于这些范围约束：

- 保留 nightly 和 weekly 两套调度周期；
- 保留单节点、2 节点和多节点调度方式；
- 保留现有硬件、镜像和部署模式；
- `pull_request` 目录暂不迁移；
- 模型精度和性能测试继续采用数据驱动方式；
- 只将适合表达行为的特性测试逐步改成直接 pytest；
- 不在本次重写整套 GitHub Actions 调度框架。

估算单位为一名熟悉 Python、pytest 和现有 CI 的工程师所需的人日。多机 NPU 任务的排队时间单独计算。

### 10.2 估算依据

当前直接相关的代码规模为：

| 项目 | 数量 |
| --- | ---: |
| nightly/weekly 已跟踪文件 | 367 |
| Python 文件 | 164 |
| pytest 测试文件 | 131 |
| YAML 配置文件 | 191 |
| Shell 脚本 | 7 |
| 同名 YAML 冲突组 | 17 |
| 包含旧路径或旧模块引用的文件 | 约 70 |
| 其中 workflow 文件 | 8 |
| 直接使用旧 Python 包路径的文件 | 37 |

大量文件移动本身是机械工作。主要成本来自配置冲突判断、路径语义解耦、历史基线兼容和真实 NPU 环境验证。

### 10.3 推荐方案工作分解

| 工作项 | 主要内容 | 估算 |
| --- | --- | ---: |
| 方案和迁移清单 | 确认分类规则、生成旧路径到新路径映射、确认 CI owner | 1～2 人日 |
| 解除周期路径耦合 | 显式传递 `test_frequency`，修改结果处理及相关测试 | 1～2 人日 |
| 解除 DP 路径耦合 | 显式传递 `dp_load_balancing` 并选择对应 runtime | 1～2 人日 |
| 公共运行代码迁移 | 整理 `common`，更新 Python 导入、Shell 入口和 fixture | 2～3 人日 |
| `ops` 和 `features` 迁移 | 移动测试、维持 `conftest.py` 作用域、更新矩阵 | 2～4 人日 |
| 模型配置迁移 | 迁移 191 个 YAML，检查并处理 17 组同名冲突 | 3～5 人日 |
| CI 矩阵与工作流调整 | 更新 nightly/weekly、单节点/2 节点/多节点的所有引用 | 2～3 人日 |
| good table 与 bisect | 路径兼容、场景标识、历史记录迁移或稳定 `case_id` | 2～3 人日 |
| 文档与静态检查 | 更新贡献文档、命令示例，执行格式和引用完整性检查 | 1～2 人日 |
| NPU CI 验证与修复 | 覆盖各周期、拓扑、硬件和部署模式的代表用例 | 3～5 人日 |

推荐方案合计约 **18～31 人日**。如果历史 good table 可以直接重新生成，且同名 YAML 很快完成确认，通常可以控制在 **18～24 人日**；如果需要完整兼容历史路径和多个 release 分支，接近区间上限。

### 10.4 不同实施范围的对比

| 实施范围 | 内容 | 工程投入 | 预计自然周期 |
| --- | --- | ---: | ---: |
| 最小迁移 | 移动目录、批量改路径，暂时保留路径推断及兼容代码 | 8～12 人日 | 2～3 周 |
| 推荐迁移 | 解除路径语义耦合、处理配置冲突、兼容 bisect 和基线 | 18～24 人日 | 3～5 周 |
| 深度重构 | 推荐迁移，加上大批特性测试 pytest 化和 CI schema 统一 | 25～40 人日 | 5～8 周 |

自然周期包含代码评审、NPU 资源排队和定时任务观察时间。两个工程师可以并行处理测试资产与 CI/runtime，但多机验证和最终切换存在先后依赖，整体周期通常不能按人数等比例缩短。

### 10.5 建议的人员安排

两人协作较合适：

- 工程师 A 负责公共 runtime、结果处理、good table、bisect 和多机入口；
- 工程师 B 负责目录迁移、YAML 冲突处理、矩阵更新和文档；
- 两人共同完成 NPU CI 验证和最终旧目录清理。

按推荐范围，两人预计需要 **2～3 周开发时间，加 1～2 周灰度观察**。如果只有一人，建议按 `ops`、`features`、`models` 分三个 PR 逐步迁移，避免形成难以审查的大型改动。

### 10.6 建议预留的风险缓冲

建议在工程投入之外预留约 20% 缓冲，主要用于：

- 多机任务排队或偶发基础设施失败；
- 同名 YAML 实际语义无法仅通过文本比较确认；
- release 分支、手动 slash command 或外部脚本仍依赖旧路径；
- good table 中历史数据需要兼容；
- 文件移动导致 pytest fixture 作用域或测试收集行为变化。
