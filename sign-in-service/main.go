package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/database"
	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/generator"
	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/repository"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.27.0"
	"go.opentelemetry.io/otel/trace"
)

const (
	serviceName    = "sign-in-service"
	serviceVersion = "1.0.0"
)

var (
	db       *database.Database
	userRepo *repository.UserRepository
)

func main() {
	ctx := context.Background()

	// Use JSON handler — matches notifications-service JSON format (time, level, msg + fields).
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	// Initialize OpenTelemetry
	shutdown, err := initTracer(ctx)
	if err != nil {
		slog.Error("Failed to initialize tracer", "error", err)
		os.Exit(1)
	}
	defer func() {
		if err := shutdown(ctx); err != nil {
			slog.Error("Failed to shutdown tracer", "error", err)
		}
	}()

	// Initialize database connection
	dbConfig := database.Config{
		Host:     getEnv("DB_HOST", "postgres"),
		Port:     getEnv("DB_PORT", "5432"),
		User:     getEnv("DB_USER", "demo"),
		Password: getEnv("DB_PASSWORD", "a_super_secure_password"),
		DBName:   getEnv("DB_NAME", "startup_centralized_database"),
	}

	db, err = database.New(ctx, dbConfig)
	if err != nil {
		slog.Error("Failed to connect to database", "error", err)
		os.Exit(1)
	}
	defer func() {
		if err := db.Close(); err != nil {
			slog.Error("Failed to close database", "error", err)
		}
	}()

	// Initialize repository
	userRepo = repository.NewUserRepository(db)

	// Ensure database schema
	if err := userRepo.EnsureSchema(ctx); err != nil {
		slog.Error("Failed to ensure database schema", "error", err)
		os.Exit(1)
	}

	// Create context with cancellation for generators
	genCtx, cancelGen := context.WithCancel(ctx)
	defer cancelGen()

	// Start user generators
	generator.StartGenerators(genCtx, userRepo)

	// Create router
	r := chi.NewRouter()

	// Middleware
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(60 * time.Second))

	// Wrap router with OpenTelemetry middleware
	handler := otelhttp.NewHandler(r, serviceName)

	// Routes
	r.Get("/health", healthHandler)
	r.Get("/", helloHandler)

	// Server configuration
	port := getEnv("PORT", "8080")
	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", port),
		Handler:      handler,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in goroutine
	go func() {
		slog.Info("Starting service", "service", serviceName, "port", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("Server failed to start", "error", err)
			os.Exit(1)
		}
	}()

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	slog.Info("Shutting down server")

	// Cancel generator context
	cancelGen()

	shutdownCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("Server forced to shutdown", "error", err)
		os.Exit(1)
	}

	slog.Info("Server exited")
}

// initTracer initializes OpenTelemetry tracer
func initTracer(ctx context.Context) (func(context.Context) error, error) {
	otelEndpoint := getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

	exporter, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(otelEndpoint),
		otlptracehttp.WithInsecure(),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	res, err := resource.New(ctx,
		// Platform-first approach:
		// - Allow OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES to drive service metadata.
		// - Provide safe fallbacks for local runs.
		resource.WithFromEnv(),
		resource.WithProcess(),
		resource.WithOS(),
		resource.WithContainer(),
		resource.WithHost(),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	// Avoid SchemaURL conflicts across different semconv versions.
	// We intentionally keep the fallback resource schemaless so that env/detectors
	// can provide (and own) the schema URL.
	fallbackRes := resource.NewWithAttributes(
		"",
		semconv.ServiceName(serviceName),
		semconv.ServiceVersion(serviceVersion),
	)
	res, err = resource.Merge(fallbackRes, res) // env/detectors override fallbacks
	if err != nil {
		return nil, fmt.Errorf("failed to merge resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return tp.Shutdown, nil
}

// healthHandler handles health check requests
func healthHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tracer := otel.Tracer(serviceName)

	// Create a span for the health check
	ctx, span := tracer.Start(ctx, "health-check")
	defer span.End()

	// Check database health
	if db != nil {
		if err := db.HealthCheck(ctx); err != nil {
			slog.Error("Database health check failed", "error", err)
			span.RecordError(err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			response := `{"status":"unhealthy","service":"sign-in-service","version":"1.0.0","error":"database_unavailable"}`
			if _, writeErr := w.Write([]byte(response)); writeErr != nil {
				slog.Error("Failed to write health response", "error", writeErr)
			}
			return
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	response := `{"status":"ok","service":"sign-in-service","version":"1.0.0"}`

	if _, err := w.Write([]byte(response)); err != nil {
		slog.Error("Failed to write health response", "error", err)
	}

	slog.Info("Health check completed")
}

// helloHandler handles root requests
func helloHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tracer := otel.Tracer(serviceName)

	// Create a span for the hello request
	ctx, span := tracer.Start(ctx, "hello-handler")
	defer span.End()

	// Add some span attributes
	span.SetAttributes(
		semconv.HTTPRequestMethodKey.String(r.Method),
		semconv.HTTPRouteKey.String(r.URL.Path),
	)

	// Simulate some processing
	if err := processRequest(ctx, tracer); err != nil {
		slog.Error("Failed to process request", "error", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)

	if _, err := w.Write([]byte("Hello, World from Sign-In Service!")); err != nil {
		slog.Error("Failed to write hello response", "error", err)
	}

	slog.Info("Hello request processed")
}

// processRequest simulates some processing with tracing
func processRequest(ctx context.Context, tracer trace.Tracer) error {
	_, span := tracer.Start(ctx, "process-request")
	defer span.End()

	// Simulate processing time
	time.Sleep(10 * time.Millisecond)

	return nil
}

// getEnv gets environment variable with fallback
func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
