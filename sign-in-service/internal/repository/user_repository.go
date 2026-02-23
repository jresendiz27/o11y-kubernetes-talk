package repository

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/database"
	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/models"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

type UserRepository struct {
	db     *database.Database
	tracer trace.Tracer
}

func NewUserRepository(db *database.Database) *UserRepository {
	return &UserRepository{
		db:     db,
		tracer: otel.Tracer("sign-in-service"),
	}
}

func (r *UserRepository) EnsureSchema(ctx context.Context) error {
	ctx, span := r.tracer.Start(ctx, "ensure-user-schema")
	defer span.End()

	query := `
	CREATE TABLE IF NOT EXISTS users (
		id SERIAL PRIMARY KEY,
		email VARCHAR(255) UNIQUE NOT NULL,
		name VARCHAR(255) NOT NULL,
		password_hash VARCHAR(255) NOT NULL,
		phone VARCHAR(50),
		address TEXT,
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	)`

	_, err := r.db.DB.ExecContext(ctx, query)
	if err != nil {
		span.RecordError(err)
		return fmt.Errorf("failed to create users table: %w", err)
	}

	slog.Info("Users table schema ensured")
	return nil
}

func (r *UserRepository) CreateUser(ctx context.Context, user *models.User) error {
	ctx, span := r.tracer.Start(ctx, "insert-user")
	defer span.End()

	span.SetAttributes(
		attribute.String("user.email", user.Email),
		attribute.String("user.name", user.Name),
	)

	query := `
		INSERT INTO users (email, name, password_hash, phone, address)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at`

	err := r.db.DB.QueryRowContext(
		ctx,
		query,
		user.Email,
		user.Name,
		user.PasswordHash,
		user.Phone,
		user.Address,
	).Scan(&user.ID, &user.CreatedAt)

	if err != nil {
		span.RecordError(err)
		return fmt.Errorf("failed to insert user: %w", err)
	}

	span.SetAttributes(attribute.Int("user.id", user.ID))
	return nil
}

func (r *UserRepository) GetUserCount(ctx context.Context) (int, error) {
	ctx, span := r.tracer.Start(ctx, "get-user-count")
	defer span.End()

	var count int
	query := "SELECT COUNT(*) FROM users"

	err := r.db.DB.QueryRowContext(ctx, query).Scan(&count)
	if err != nil {
		span.RecordError(err)
		return 0, fmt.Errorf("failed to count users: %w", err)
	}

	span.SetAttributes(attribute.Int("user.count", count))
	return count, nil
}
