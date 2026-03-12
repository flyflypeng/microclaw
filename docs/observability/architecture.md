# Observability Architecture

本文档描述 `microclaw-observability` crate 的架构分层、适配器扩展点和配置矩阵，目标是让后续接入 AgentOps、Arize 等平台时可以按统一方式扩展。

## 1. 设计目标

- 统一三类信号：Metrics / Traces / Logs
- 统一 OTLP 导出：优先复用 `opentelemetry` / `opentelemetry-sdk` / `opentelemetry-otlp`
- 统一资源语义：`service.name` 等资源属性在三类信号一致
- 统一扩展方式：平台差异收敛在 adapter 层，不侵入业务采集逻辑

## 2. 分层架构

```text
microclaw (app/runtime/agent/web)
        |
        v
crates/microclaw-observability
  ├─ sdk.rs        (共享上下文/资源/配置解析)
  ├─ metrics.rs    (OTLP Metrics exporter + 业务指标映射)
  ├─ traces.rs     (OTLP Traces exporter + SpanData 映射)
  ├─ logs.rs       (OTLP Logs exporter + LogRecord 映射)
  └─ adapters/
      ├─ langfuse.rs   (Langfuse 端点/认证注入)
      └─ agentops.rs   (AgentOps 端点/认证注入)
```

### 2.1 SDK 层（共享能力）

- 文件：`crates/microclaw-observability/src/sdk.rs`
- 职责：
  - 构建共享 `OTelSdkContext`（`Resource` + `service_name`）
  - 提供统一配置读取函数：`get_trimmed` / `get_u64` / `get_bool` / `parse_headers`

### 2.2 信号层（Metrics/Traces/Logs）

- `metrics.rs`
  - `OtlpMetricExporter`
  - 使用 `SdkMeterProvider + PeriodicReader + opentelemetry_otlp::MetricExporter`
  - 将运行时快照映射成 OTel Counter / UpDownCounter
- `traces.rs`
  - `OtlpTraceExporter`
  - 使用 `SdkTracerProvider + opentelemetry_otlp::SpanExporter`
  - 将 `SpanData` 映射为 SDK span（支持 parent context、status、kind）
- `logs.rs`
  - `OtlpLogExporter`
  - 使用 `SdkLoggerProvider + BatchLogProcessor + opentelemetry_otlp::LogExporter`
  - 将 `OtlpLogRecord` 映射为 SDK log record

### 2.3 适配器层（Vendor 扩展）

- 入口文件：`crates/microclaw-observability/src/adapters/mod.rs`
- 当前定义：
  - `TraceTargetConfig { endpoint, headers }`
  - 各平台 adapter 通过 `apply(map, &mut target)` 注入 endpoint 和认证头

## 3. 运行时数据流

### 3.1 Metrics

1. `runtime::AppState.metric_exporter` 初始化 `OtlpMetricExporter`
2. Web 指标快照在 `web.rs` 中进入 `enqueue_metrics`
3. `OtlpMetricExporter` 计算增量并写入 OTel instruments
4. `PeriodicReader` 按 `otlp_export_interval_seconds` 周期导出

### 3.2 Traces

1. `runtime::AppState.trace_exporter` 初始化 `OtlpTraceExporter`
2. `agent_engine.rs` 生成 `SpanData`（`agent_run` / `llm_generation` / `tool_execution`）
3. `send_span` 将 `SpanData` 映射为 SDK span 并结束
4. Batch exporter 异步导出到目标平台

### 3.3 Logs

1. `runtime::AppState.log_exporter` 初始化 `OtlpLogExporter`
2. 业务侧调用 `send_log` 发送 `OtlpLogRecord`
3. SDK Logger + BatchLogProcessor 聚合后导出

## 4. Adapter 扩展点规范

新增一个可观测平台时，建议遵循以下契约：

1. 在 `adapters/<vendor>.rs` 新增 `apply(map: &Mapping, target: &mut TraceTargetConfig)`
2. 只做目标地址和鉴权头注入，不在 adapter 里做信号业务逻辑
3. 遵循优先级：
   - 显式 `otlp_tracing_endpoint` 优先
   - 若未显式设置，再由 adapter 推断默认 endpoint
4. 头部处理保持幂等：
   - 仅在未存在 `authorization` 时注入默认认证头

### 4.1 Langfuse

- 文件：`adapters/langfuse.rs`
- 配置：
  - `langfuse_host`
  - `langfuse_public_key`
  - `langfuse_secret_key`
- 行为：
  - 默认 endpoint：`{host}/api/public/otel/v1/traces`
  - 认证方式：`Authorization: Basic base64(pk:sk)`

### 4.2 AgentOps

- 文件：`adapters/agentops.rs`
- 配置：
  - `agentops_api_key`
  - `agentops_otlp_endpoint`
- 行为：
  - 认证方式：`Authorization: Bearer <api_key>`

### 4.3 Arize（建议扩展方案）

建议新增 `adapters/arize.rs`，使用以下建议配置键：

- `arize_api_key`
- `arize_space_id`（若平台需要）
- `arize_otlp_endpoint`

建议行为：

- 若用户未设置 `arize_otlp_endpoint`，按官方文档拼默认 region endpoint
- 注入平台要求的鉴权头（Bearer 或平台自定义 header）
- 仅注入 endpoint/header，不改动 traces/metrics/logs 的核心采集逻辑

## 5. 配置矩阵

| 配置键                                       | 层级             | 类型               | 用途                             | 默认值                              | 当前支持            |
| -------------------------------------------- | ---------------- | ------------------ | -------------------------------- | ----------------------------------- | ------------------- |
| `observability.service_name`                 | sdk              | string             | 设置 OTel `service.name`         | `microclaw`                         | Metrics/Traces/Logs |
| `observability.otlp_headers`                 | sdk              | map<string,string> | 通用 OTLP header                 | 空                                  | Metrics/Traces/Logs |
| `observability.otlp_enabled`                 | metrics          | bool               | 启用 metrics 导出                | `false`                             | ✅                   |
| `observability.otlp_endpoint`                | metrics          | string             | Metrics OTLP endpoint            | 无                                  | ✅                   |
| `observability.otlp_export_interval_seconds` | metrics          | int                | Metrics 导出周期                 | `15`                                | ✅                   |
| `observability.otlp_tracing_enabled`         | traces           | bool               | 启用 traces 导出                 | `false`（若有 endpoint 则自动启用） | ✅                   |
| `observability.otlp_tracing_endpoint`        | traces           | string             | Traces OTLP endpoint（显式优先） | 无                                  | ✅                   |
| `observability.otlp_logs_enabled`            | logs             | bool               | 启用 logs 导出                   | `false`                             | ✅                   |
| `observability.otlp_logs_endpoint`           | logs             | string             | Logs OTLP endpoint               | 无                                  | ✅                   |
| `observability.langfuse_host`                | adapter/langfuse | string             | Langfuse host                    | `https://cloud.langfuse.com`        | ✅                   |
| `observability.langfuse_public_key`          | adapter/langfuse | string             | Langfuse public key              | 无                                  | ✅                   |
| `observability.langfuse_secret_key`          | adapter/langfuse | string             | Langfuse secret key              | 无                                  | ✅                   |
| `observability.agentops_api_key`             | adapter/agentops | string             | AgentOps API key                 | 无                                  | ✅                   |
| `observability.agentops_otlp_endpoint`       | adapter/agentops | string             | AgentOps OTLP endpoint           | 无                                  | ✅                   |
| `observability.arize_api_key`                | adapter/arize    | string             | Arize API key                    | 无                                  | 🚧（建议）           |
| `observability.arize_otlp_endpoint`          | adapter/arize    | string             | Arize OTLP endpoint              | 无                                  | 🚧（建议）           |

## 6. 建议的落地顺序（新增平台）

1. 新增 `adapters/<vendor>.rs` 并实现 `apply`
2. 在 `adapters/mod.rs` 导出新模块
3. 在 `traces.rs`（必要时 metrics/logs）注册 `adapter.apply(...)`
4. 在 `microclaw.config.example.yaml` 增加配置样例
5. 在 README / docs 更新配置说明和验证步骤
6. 通过 `cargo check` 与 `cargo clippy --all-targets --all-features -- -D warnings` 校验

## 7. 当前边界与后续优化

- 当前 adapter 主要作用于 traces 目标配置（`TraceTargetConfig`）
- 若后续平台对 metrics/logs 也有独立 endpoint/鉴权要求，建议抽象 `SignalTargetConfig`（trace/metric/log 分开）
- 目前 logs 语义字段映射较轻量，可后续对齐更完整 OTel semconv
