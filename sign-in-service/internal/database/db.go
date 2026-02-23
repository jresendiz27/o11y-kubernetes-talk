package database

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"time"

	_ "github.com/lib/pq"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

const (
	maxOpenConns    = 25
	maxIdleConns    = 25
	connMaxLifetime = 5 * time.Minute
	connMaxIdleTime = 5 * time.Minute
)

type Database struct {
	DB     *sql.DB
	tracer trace.Tracer
}

type Config struct {
	Host     string
	Port     string
	User     string
	Password string
	DBName   string
}

func New(ctx context.Context, cfg Config) (*Database, error) {
	tracer := otel.Tracer("sign-in-service")

	ctx, span := tracer.Start(ctx, "database-connection-init")
	defer span.End()

	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		cfg.Host, cfg.Port, cfg.User, cfg.Password, cfg.DBName)

	span.SetAttributes(
		attribute.String("db.system", "postgresql"),
		attribute.String("db.name", cfg.DBName),
		attribute.String("db.host", cfg.Host),
		attribute.String("db.port", cfg.Port),
	)

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("failed to open database connection: %w", err)
	}

	// Configure connection pool
	db.SetMaxOpenConns(maxOpenConns)
	db.SetMaxIdleConns(maxIdleConns)
	db.SetConnMaxLifetime(connMaxLifetime)
	db.SetConnMaxIdleTime(connMaxIdleTime)

	// Verify connection
	if err := db.PingContext(ctx); err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}

	slog.Info("Database connection established successfully to %s:%s/%s", cfg.Host, cfg.Port, cfg.DBName)

	return &Database{
		DB:     db,
		tracer: tracer,
	}, nil
}

func (d *Database) Close() error {
	slog.Info("Closing database connection")
	return d.DB.Close()
}

func (d *Database) HealthCheck(ctx context.Context) error {
	ctx, span := d.tracer.Start(ctx, "database-health-check")
	defer span.End()

	if err := d.DB.PingContext(ctx); err != nil {
		span.RecordError(err)
		return fmt.Errorf("database health check failed: %w", err)
	}

	return nil
}
