package generator

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/jaswdr/faker"
	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/models"
	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/repository"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

const (
	minWaitSeconds = 120
	maxWaitSeconds = 360 // 3 minutes
)

type UserGenerator struct {
	repo                    *repository.UserRepository
	faker                   faker.Faker
	tracer                  trace.Tracer
	logUserData             bool
	notificationsServiceURL string
	httpClient              *http.Client
}

func NewUserGenerator(repo *repository.UserRepository) *UserGenerator {
	logUserData := false
	if val := os.Getenv("LOG_USER_DATA"); val == "true" {
		logUserData = true
	}

	notifURL := os.Getenv("NOTIFICATIONS_SERVICE_URL")
	if notifURL == "" {
		notifURL = "http://notifications-service:8081"
	}

	return &UserGenerator{
		repo:                    repo,
		faker:                   faker.New(),
		tracer:                  otel.Tracer("sign-in-service"),
		logUserData:             logUserData,
		notificationsServiceURL: notifURL,
		httpClient: &http.Client{
			Timeout:   30 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		},
	}
}

func (g *UserGenerator) GenerateAndInsertUser(ctx context.Context) error {
	ctx, span := g.tracer.Start(ctx, "generate-and-insert-user")
	defer span.End()

	person := g.faker.Person()
	address := g.faker.Address()
	internet := g.faker.Internet()

	var randEmail = fmt.Sprintf("%s_%d_%s", person.FirstName(), rand.Intn(100), internet.Email())

	user := &models.User{
		Email:        randEmail,
		Name:         person.Name(),
		PasswordHash: internet.Password(),
		Phone:        person.Contact().Phone,
		Address:      fmt.Sprintf("%s, %s, %s", address.StreetAddress(), address.City(), address.Country()),
	}

	span.SetAttributes(
		attribute.String("user.email", user.Email),
		attribute.String("user.name", user.Name),
	)

	err := g.repo.CreateUser(ctx, user)
	if err != nil {
		span.RecordError(err)
		log.Printf("Failed to insert user: %v", err)
		return err
	}

	// Conditional logging based on LOG_USER_DATA environment variable
	if g.logUserData {
		log.Printf("User inserted successfully, email: %s, name: %s, phone: %s, address: %s",
			user.Email, user.Name, user.Phone, user.Address)
	} else {
		log.Printf("User inserted successfully, id: %d", user.ID)
	}

	// Send welcome email notification (fire-and-forget, do not fail user creation)
	if err := g.sendWelcomeEmail(ctx, user); err != nil {
		log.Printf("Failed to send welcome email notification for user %d: %v", user.ID, err)
	}

	return nil
}

// sendWelcomeEmail calls the notifications-service to emulate sending a welcome email.
// Errors are logged but do not propagate -- notification failure must not block user creation.
func (g *UserGenerator) sendWelcomeEmail(ctx context.Context, user *models.User) error {
	ctx, span := g.tracer.Start(ctx, "send-welcome-email-notification")
	defer span.End()

	span.SetAttributes(
		attribute.String("notification.type", "email"),
		attribute.String("notification.recipient", user.Email),
		attribute.Int("notification.user_id", user.ID),
	)

	payload := map[string]string{
		"to":      user.Email,
		"subject": "Welcome to our platform!",
		"body":    fmt.Sprintf("Hello %s, welcome aboard!", user.Name),
	}

	body, err := json.Marshal(payload)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "failed to marshal notification payload")
		return fmt.Errorf("failed to marshal notification payload: %w", err)
	}

	url := fmt.Sprintf("%s/notifications/email", g.notificationsServiceURL)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "failed to create notification request")
		return fmt.Errorf("failed to create notification request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	log.Printf("Sending welcome email notification for user %d to %s", user.ID, user.Email)

	resp, err := g.httpClient.Do(req)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "notification request failed")
		return fmt.Errorf("notification request failed: %w", err)
	}
	defer resp.Body.Close()

	span.SetAttributes(attribute.Int("notification.response_status", resp.StatusCode))

	if resp.StatusCode >= 400 {
		errMsg := fmt.Sprintf("notifications-service returned status %d", resp.StatusCode)
		span.RecordError(fmt.Errorf(errMsg))
		span.SetStatus(codes.Error, errMsg)
		log.Printf("Welcome email notification failed for user %d: %s", user.ID, errMsg)
		return fmt.Errorf(errMsg)
	}

	log.Printf("Welcome email notification sent for user %d", user.ID)
	return nil
}

func (g *UserGenerator) StartGenerator(ctx context.Context, generatorID int) {
	log.Printf("Starting user generator %d", generatorID)

	for {
		select {
		case <-ctx.Done():
			log.Printf("Stopping user generator %d", generatorID)
			return
		default:
			// Random wait between 30s and 3 minutes
			waitSeconds := rand.Intn(maxWaitSeconds-minWaitSeconds) + minWaitSeconds
			log.Printf("Generator %d waiting %d seconds before next user creation", generatorID, waitSeconds)

			timer := time.NewTimer(time.Duration(waitSeconds) * time.Second)
			select {
			case <-ctx.Done():
				timer.Stop()
				log.Printf("Stopping user generator %d", generatorID)
				return
			case <-timer.C:
				if err := g.GenerateAndInsertUser(ctx); err != nil {
					log.Printf("Generator %d failed to generate user: %v", generatorID, err)
				}
			}
		}
	}
}

func StartGenerators(ctx context.Context, repo *repository.UserRepository) {
	numGenerators := 5
	if val := os.Getenv("NUM_GENERATORS"); val != "" {
		if n, err := strconv.Atoi(val); err == nil && n > 0 {
			numGenerators = n
		}
	}

	log.Printf("Starting %d user generators", numGenerators)

	generator := NewUserGenerator(repo)

	for i := 1; i <= numGenerators; i++ {
		go generator.StartGenerator(ctx, i)
	}
}
