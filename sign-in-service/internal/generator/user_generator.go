package generator

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strconv"
	"time"

	"github.com/jaswdr/faker"
	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/models"
	"github.com/jresendiz/o11y-kubernetes-talk/sign-in-service/internal/repository"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

const (
	minWaitSeconds = 30
	maxWaitSeconds = 180 // 3 minutes
)

type UserGenerator struct {
	repo        *repository.UserRepository
	faker       faker.Faker
	tracer      trace.Tracer
	logUserData bool
}

func NewUserGenerator(repo *repository.UserRepository) *UserGenerator {
	logUserData := false
	if val := os.Getenv("LOG_USER_DATA"); val == "true" {
		logUserData = true
	}

	return &UserGenerator{
		repo:        repo,
		faker:       faker.New(),
		tracer:      otel.Tracer("sign-in-service"),
		logUserData: logUserData,
	}
}

func (g *UserGenerator) GenerateAndInsertUser(ctx context.Context) error {
	ctx, span := g.tracer.Start(ctx, "generate-and-insert-user")
	defer span.End()

	person := g.faker.Person()
	address := g.faker.Address()
	internet := g.faker.Internet()

	user := &models.User{
		Email:        internet.Email(),
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
