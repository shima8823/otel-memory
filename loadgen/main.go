// loadgen - OpenTelemetry Collector の負荷テスト用ツール
// memory_limiter を発火させるための高負荷シナリオを提供
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	otellog "go.opentelemetry.io/otel/log"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/metric"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// Config は負荷テストの設定
type Config struct {
	Endpoint        string
	Scenario        string
	Duration        time.Duration
	WorkerCount     int
	SpansPerSecond  int
	SpanDepth       int
	AttributeSize   int  // 属性値の文字列長（メモリ消費に影響）
	AttributeCount  int  // 属性の数
	MetricsEnabled  bool // メトリクスも送るか
	LogsEnabled     bool // ログも送るか
	HighCardinality bool // 高カーディナリティ属性を使うか（シナリオ6用）
}

var (
	totalSpans atomic.Int64
	totalLogs  atomic.Int64
)

func main() {
	cfg := parseFlags()

	log.Printf("========================================")
	log.Printf("Loadgen starting...")
	log.Printf("  Endpoint:         %s", cfg.Endpoint)
	log.Printf("  Scenario:         %s", cfg.Scenario)
	log.Printf("  Duration:         %s", cfg.Duration)
	log.Printf("  Workers:          %d", cfg.WorkerCount)
	log.Printf("  Spans/sec:        %d", cfg.SpansPerSecond)
	log.Printf("  Span Depth:       %d", cfg.SpanDepth)
	log.Printf("  Attribute Size:   %d bytes", cfg.AttributeSize)
	log.Printf("  Attribute Count:  %d", cfg.AttributeCount)
	log.Printf("  Metrics:          %v", cfg.MetricsEnabled)
	log.Printf("  Logs:             %v", cfg.LogsEnabled)
	log.Printf("  High Cardinality: %v", cfg.HighCardinality)
	log.Printf("========================================")

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	// gRPC 接続
	conn, err := grpc.NewClient(cfg.Endpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		log.Fatalf("Failed to create gRPC connection: %v", err)
	}
	defer conn.Close()

	// Resource 作成
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName("loadgen"),
			semconv.ServiceVersion("1.0.0"),
		),
	)
	if err != nil {
		log.Fatalf("Failed to create resource: %v", err)
	}

	// Tracer Provider 初期化
	tracerProvider, err := initTracerProvider(ctx, res, conn)
	if err != nil {
		log.Fatalf("Failed to init tracer provider: %v", err)
	}
	defer func() {
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		if err := tracerProvider.Shutdown(shutdownCtx); err != nil {
			log.Printf("Error shutting down tracer provider: %v", err)
		}
	}()

	// Meter Provider 初期化（オプション）
	var meterProvider *sdkmetric.MeterProvider
	if cfg.MetricsEnabled {
		meterProvider, err = initMeterProvider(ctx, res, conn)
		if err != nil {
			log.Fatalf("Failed to init meter provider: %v", err)
		}
		defer func() {
			shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer shutdownCancel()
			if err := meterProvider.Shutdown(shutdownCtx); err != nil {
				log.Printf("Error shutting down meter provider: %v", err)
			}
		}()
	}

	// Logger Provider 初期化（オプション）
	var loggerProvider *sdklog.LoggerProvider
	if cfg.LogsEnabled {
		loggerProvider, err = initLoggerProvider(ctx, res, conn)
		if err != nil {
			log.Fatalf("Failed to init logger provider: %v", err)
		}
		defer func() {
			shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer shutdownCancel()
			if err := loggerProvider.Shutdown(shutdownCtx); err != nil {
				log.Printf("Error shutting down logger provider: %v", err)
			}
		}()
	}

	tracer := otel.Tracer("loadgen")
	var meter metric.Meter
	if cfg.MetricsEnabled {
		meter = otel.Meter("loadgen")
	}
	var logger otellog.Logger
	if cfg.LogsEnabled {
		logger = global.GetLoggerProvider().Logger("loadgen")
	}

	// シナリオ実行
	runScenario(ctx, cfg, tracer, meter, logger)

	log.Printf("========================================")
	log.Printf("Loadgen finished")
	log.Printf("  Total spans sent: %d", totalSpans.Load())
	if cfg.LogsEnabled {
		log.Printf("  Total logs sent:  %d", totalLogs.Load())
	}
	log.Printf("========================================")
}

func parseFlags() Config {
	cfg := Config{}

	flag.StringVar(&cfg.Endpoint, "endpoint", "localhost:4317", "OTel Collector endpoint")
	flag.StringVar(&cfg.Scenario, "scenario", "sustained", "Load scenario: burst, sustained, spike, rampup")
	flag.DurationVar(&cfg.Duration, "duration", 60*time.Second, "Test duration")
	flag.IntVar(&cfg.WorkerCount, "workers", 10, "Number of concurrent workers")
	flag.IntVar(&cfg.SpansPerSecond, "rate", 1000, "Target spans per second (total across all workers)")
	flag.IntVar(&cfg.SpanDepth, "depth", 5, "Span nesting depth per trace")
	flag.IntVar(&cfg.AttributeSize, "attr-size", 256, "Size of each attribute value in bytes")
	flag.IntVar(&cfg.AttributeCount, "attr-count", 10, "Number of attributes per span")
	flag.BoolVar(&cfg.MetricsEnabled, "metrics", true, "Enable metrics generation")
	flag.BoolVar(&cfg.LogsEnabled, "logs", true, "Enable logs generation")
	flag.BoolVar(&cfg.HighCardinality, "high-cardinality", false, "Use high cardinality attributes (UUID per span)")

	flag.Parse()
	return cfg
}

func initTracerProvider(ctx context.Context, res *resource.Resource, conn *grpc.ClientConn) (*sdktrace.TracerProvider, error) {
	exporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
	if err != nil {
		return nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	// BatchSpanProcessor - gRPC の 4MiB 制限を超えないようにバッチサイズを調整
	// 大きな属性を持つスパンでも 4MiB に収まるよう、小さいバッチで頻繁に送信
	bsp := sdktrace.NewBatchSpanProcessor(exporter,
		sdktrace.WithMaxQueueSize(4096),                // キューサイズ
		sdktrace.WithMaxExportBatchSize(32),            // 小さいバッチ（4MiB制限内に確実に収める）
		sdktrace.WithBatchTimeout(50*time.Millisecond), // 短いタイムアウトで頻繁に送信
	)

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
		sdktrace.WithResource(res),
		sdktrace.WithSpanProcessor(bsp),
	)
	otel.SetTracerProvider(tp)

	return tp, nil
}

func initMeterProvider(ctx context.Context, res *resource.Resource, conn *grpc.ClientConn) (*sdkmetric.MeterProvider, error) {
	exporter, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithGRPCConn(conn))
	if err != nil {
		return nil, fmt.Errorf("failed to create metric exporter: %w", err)
	}

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter, sdkmetric.WithInterval(1*time.Second))),
	)
	otel.SetMeterProvider(mp)

	return mp, nil
}

func initLoggerProvider(ctx context.Context, res *resource.Resource, conn *grpc.ClientConn) (*sdklog.LoggerProvider, error) {
	exporter, err := otlploggrpc.New(ctx, otlploggrpc.WithGRPCConn(conn))
	if err != nil {
		return nil, fmt.Errorf("failed to create log exporter: %w", err)
	}

	// BatchProcessor for logs
	batchProcessor := sdklog.NewBatchProcessor(exporter,
		sdklog.WithMaxQueueSize(4096),
		sdklog.WithExportMaxBatchSize(32),
		sdklog.WithExportInterval(50*time.Millisecond),
	)

	lp := sdklog.NewLoggerProvider(
		sdklog.WithResource(res),
		sdklog.WithProcessor(batchProcessor),
	)
	global.SetLoggerProvider(lp)

	return lp, nil
}

func runScenario(ctx context.Context, cfg Config, tracer trace.Tracer, meter metric.Meter, logger otellog.Logger) {
	switch cfg.Scenario {
	case "burst":
		runBurstScenario(ctx, cfg, tracer, meter, logger)
	case "sustained":
		runSustainedScenario(ctx, cfg, tracer, meter, logger)
	case "spike":
		runSpikeScenario(ctx, cfg, tracer, meter, logger)
	case "rampup":
		runRampupScenario(ctx, cfg, tracer, meter, logger)
	default:
		log.Fatalf("Unknown scenario: %s", cfg.Scenario)
	}
}

// burst: 可能な限り速くスパンを送り続ける（rate制限なし）
func runBurstScenario(ctx context.Context, cfg Config, tracer trace.Tracer, meter metric.Meter, logger otellog.Logger) {
	log.Println("[BURST] Starting burst mode - sending as fast as possible")

	deadline := time.Now().Add(cfg.Duration)
	var wg sync.WaitGroup

	for i := 0; i < cfg.WorkerCount; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for time.Now().Before(deadline) {
				select {
				case <-ctx.Done():
					return
				default:
					generateTrace(ctx, tracer, meter, logger, cfg, workerID)
				}
			}
		}(i)
	}

	// 進捗レポート
	go reportProgress(ctx, deadline, cfg.LogsEnabled)

	wg.Wait()
}

// sustained: 指定レートで継続的に送り続ける
func runSustainedScenario(ctx context.Context, cfg Config, tracer trace.Tracer, meter metric.Meter, logger otellog.Logger) {
	log.Printf("[SUSTAINED] Target rate: %d spans/sec for %s", cfg.SpansPerSecond, cfg.Duration)

	deadline := time.Now().Add(cfg.Duration)
	var wg sync.WaitGroup

	// 各ワーカーの送信レート
	// 1トレースで depth+1 スパン生成するので、トレース生成レートを調整
	spansPerTrace := cfg.SpanDepth + 1
	tracesPerSecond := cfg.SpansPerSecond / spansPerTrace
	ratePerWorker := tracesPerSecond / cfg.WorkerCount
	if ratePerWorker < 1 {
		ratePerWorker = 1
	}
	interval := time.Second / time.Duration(ratePerWorker)

	for i := 0; i < cfg.WorkerCount; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			ticker := time.NewTicker(interval)
			defer ticker.Stop()

			for time.Now().Before(deadline) {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					generateTrace(ctx, tracer, meter, logger, cfg, workerID)
				}
			}
		}(i)
	}

	go reportProgress(ctx, deadline, cfg.LogsEnabled)

	wg.Wait()
}

// spike: 通常負荷 → スパイク → 通常負荷 を繰り返す
func runSpikeScenario(ctx context.Context, cfg Config, tracer trace.Tracer, meter metric.Meter, logger otellog.Logger) {
	log.Println("[SPIKE] Alternating between normal and spike load")

	deadline := time.Now().Add(cfg.Duration)
	var wg sync.WaitGroup

	normalRate := cfg.SpansPerSecond / 10 // 通常は1/10
	spikeRate := cfg.SpansPerSecond       // スパイク時はフルレート

	currentRate := &atomic.Int64{}
	currentRate.Store(int64(normalRate))

	// レート切り替えゴルーチン
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		isSpike := false

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if time.Now().After(deadline) {
					return
				}
				isSpike = !isSpike
				if isSpike {
					log.Printf("[SPIKE] 🔥 SPIKE START - rate: %d/sec", spikeRate)
					currentRate.Store(int64(spikeRate))
				} else {
					log.Printf("[SPIKE] 😌 Normal mode - rate: %d/sec", normalRate)
					currentRate.Store(int64(normalRate))
				}
			}
		}
	}()

	for i := 0; i < cfg.WorkerCount; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for time.Now().Before(deadline) {
				select {
				case <-ctx.Done():
					return
				default:
					rate := currentRate.Load()
					ratePerWorker := rate / int64(cfg.WorkerCount)
					if ratePerWorker < 1 {
						ratePerWorker = 1
					}
					interval := time.Second / time.Duration(ratePerWorker)
					time.Sleep(interval)
					generateTrace(ctx, tracer, meter, logger, cfg, workerID)
				}
			}
		}(i)
	}

	go reportProgress(ctx, deadline, cfg.LogsEnabled)

	wg.Wait()
}

// rampup: 徐々に負荷を上げていく
func runRampupScenario(ctx context.Context, cfg Config, tracer trace.Tracer, meter metric.Meter, logger otellog.Logger) {
	log.Println("[RAMPUP] Gradually increasing load")

	deadline := time.Now().Add(cfg.Duration)
	var wg sync.WaitGroup

	currentRate := &atomic.Int64{}
	currentRate.Store(int64(cfg.SpansPerSecond / 10))

	// 10秒ごとにレートを上げる
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		step := int64(cfg.SpansPerSecond / 10)
		maxRate := int64(cfg.SpansPerSecond)

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if time.Now().After(deadline) {
					return
				}
				newRate := currentRate.Load() + step
				if newRate > maxRate {
					newRate = maxRate
				}
				currentRate.Store(newRate)
				log.Printf("[RAMPUP] 📈 Rate increased to %d/sec", newRate)
			}
		}
	}()

	for i := 0; i < cfg.WorkerCount; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for time.Now().Before(deadline) {
				select {
				case <-ctx.Done():
					return
				default:
					rate := currentRate.Load()
					ratePerWorker := rate / int64(cfg.WorkerCount)
					if ratePerWorker < 1 {
						ratePerWorker = 1
					}
					interval := time.Second / time.Duration(ratePerWorker)
					time.Sleep(interval)
					generateTrace(ctx, tracer, meter, logger, cfg, workerID)
				}
			}
		}(i)
	}

	go reportProgress(ctx, deadline, cfg.LogsEnabled)

	wg.Wait()
}

// generateTrace はネストされたスパンを生成
func generateTrace(ctx context.Context, tracer trace.Tracer, meter metric.Meter, logger otellog.Logger, cfg Config, workerID int) {
	// 大きな属性を生成（メモリ消費用）
	attrs := generateAttributes(cfg.AttributeCount, cfg.AttributeSize, workerID, cfg.HighCardinality)

	// ルートスパン
	ctx, rootSpan := tracer.Start(ctx, fmt.Sprintf("worker-%d-root", workerID),
		trace.WithAttributes(attrs...),
	)

	// ネストされた子スパンを生成
	generateNestedSpans(ctx, tracer, cfg, workerID, cfg.SpanDepth, attrs)

	rootSpan.End()
	totalSpans.Add(int64(cfg.SpanDepth + 1))

	// メトリクスも送る
	if meter != nil {
		counter, _ := meter.Int64Counter("loadgen.traces.generated")
		counter.Add(ctx, 1, metric.WithAttributes(
			attribute.Int("worker_id", workerID),
		))
	}

	// ログも送る
	if logger != nil {
		generateLog(ctx, logger, cfg, workerID, attrs)
	}
}

func generateNestedSpans(ctx context.Context, tracer trace.Tracer, cfg Config, workerID int, depth int, attrs []attribute.KeyValue) {
	if depth <= 0 {
		return
	}

	ctx, span := tracer.Start(ctx, fmt.Sprintf("worker-%d-child-%d", workerID, depth),
		trace.WithAttributes(attrs...),
	)
	defer span.End()

	// ランダムな処理時間をシミュレート（少し遅延を入れる）
	time.Sleep(time.Duration(rand.Intn(5)) * time.Millisecond)

	generateNestedSpans(ctx, tracer, cfg, workerID, depth-1, attrs)
}

// generateAttributes は大きな属性を生成する
func generateAttributes(count, size int, workerID int, highCardinality bool) []attribute.KeyValue {
	attrs := make([]attribute.KeyValue, count)

	// 大きな文字列を生成
	bigValue := strings.Repeat("x", size)

	for i := 0; i < count; i++ {
		var value string
		if highCardinality {
			// 高カーディナリティ: 毎回ユニークなUUIDを含める
			value = fmt.Sprintf("%s_worker%d_attr%d_%s", bigValue, workerID, i, uuid.New().String())
		} else {
			value = fmt.Sprintf("%s_worker%d_attr%d_%d", bigValue, workerID, i, rand.Int())
		}
		attrs[i] = attribute.String(
			fmt.Sprintf("attr_%d", i),
			value,
		)
	}

	return attrs
}

// generateLog は OTel ログを生成する
func generateLog(ctx context.Context, logger otellog.Logger, cfg Config, workerID int, attrs []attribute.KeyValue) {
	// 大きなログメッセージを生成
	logBody := strings.Repeat("Log message content. ", cfg.AttributeSize/20+1)

	// otellog.KeyValue に変換
	logAttrs := make([]otellog.KeyValue, len(attrs))
	for i, attr := range attrs {
		logAttrs[i] = otellog.String(string(attr.Key), attr.Value.AsString())
	}

	// ログレコードを作成
	record := otellog.Record{}
	record.SetTimestamp(time.Now())
	record.SetBody(otellog.StringValue(fmt.Sprintf("[Worker-%d] %s", workerID, logBody)))
	record.SetSeverity(otellog.SeverityInfo)
	record.AddAttributes(logAttrs...)

	logger.Emit(ctx, record)
	totalLogs.Add(1)
}

func reportProgress(ctx context.Context, deadline time.Time, logsEnabled bool) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	lastSpanCount := int64(0)
	lastLogCount := int64(0)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if time.Now().After(deadline) {
				return
			}
			currentSpans := totalSpans.Load()
			spanRate := (currentSpans - lastSpanCount) / 5
			remaining := time.Until(deadline).Round(time.Second)

			if logsEnabled {
				currentLogs := totalLogs.Load()
				logRate := (currentLogs - lastLogCount) / 5
				log.Printf("[PROGRESS] Spans: %d (%d/sec), Logs: %d (%d/sec), Remaining: %s",
					currentSpans, spanRate, currentLogs, logRate, remaining)
				lastLogCount = currentLogs
			} else {
				log.Printf("[PROGRESS] Spans: %d (rate: %d/sec), Remaining: %s", currentSpans, spanRate, remaining)
			}
			lastSpanCount = currentSpans
		}
	}
}
