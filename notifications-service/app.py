"""Notifications Service - Emulates email sending with OpenTelemetry tracing."""

import json
import logging
import os
import random
import time

from flask import Flask, jsonify, request
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.semconv.resource import ResourceAttributes
from opentelemetry.trace import StatusCode

SERVICE_NAME = "notifications-service"
SERVICE_VERSION = "1.0.0"

# --- Logging setup -----------------------------------------------------------

LOG_FORMAT = (
    "%(asctime)s %(levelname)s [%(name)s] "
    "[trace_id=%(otelTraceID)s span_id=%(otelSpanID)s] %(message)s"
)


class OTelLogFormatter(logging.Formatter):
    """Inject OTel trace/span IDs into every log record."""

    def format(self, record):
        span = trace.get_current_span()
        ctx = span.get_span_context() if span else None
        if ctx and ctx.is_valid:
            record.otelTraceID = format(ctx.trace_id, "032x")
            record.otelSpanID = format(ctx.span_id, "016x")
        else:
            record.otelTraceID = "0" * 32
            record.otelSpanID = "0" * 16
        return super().format(record)


handler = logging.StreamHandler()
handler.setFormatter(OTelLogFormatter(LOG_FORMAT))
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger(SERVICE_NAME)

# --- OpenTelemetry setup ------------------------------------------------------


def init_tracer() -> TracerProvider:
    """Initialize the OTel tracer provider with OTLP HTTP exporter."""
    otel_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
    # The OTLP HTTP exporter expects the full base URL (scheme://host:port)
    endpoint_url = f"{otel_endpoint}/v1/traces"

    resource = Resource.create(
        {
            ResourceAttributes.SERVICE_NAME: SERVICE_NAME,
            ResourceAttributes.SERVICE_VERSION: SERVICE_VERSION,
        }
    )

    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=endpoint_url)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    logger.info("OpenTelemetry tracer initialized, endpoint: %s", otel_endpoint)
    return provider


# --- Flask app ----------------------------------------------------------------

tp = init_tracer()
tracer = trace.get_tracer(SERVICE_NAME, SERVICE_VERSION)

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

# Configuration
FAILURE_RATE = float(os.getenv("FAILURE_RATE", "0.15"))
MIN_DELAY_SECONDS = float(os.getenv("MIN_DELAY_SECONDS", "2"))
MAX_DELAY_SECONDS = float(os.getenv("MAX_DELAY_SECONDS", "5"))


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint."""
    return jsonify(
        {
            "status": "ok",
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
        }
    ), 200


@app.route("/notifications/email", methods=["POST"])
def send_email():
    """Emulate sending an email notification.

    Expected JSON body:
        {"to": "user@example.com", "subject": "...", "body": "..."}

    Simulates a delay (2-5 s) and has a configurable chance of failure (~15 %)
    so that error scenarios can be observed through the o11y stack.
    """
    data = request.get_json(silent=True) or {}

    recipient = data.get("to", "unknown")
    subject = data.get("subject", "(no subject)")

    current_span = trace.get_current_span()
    current_span.set_attribute("email.recipient", recipient)
    current_span.set_attribute("email.subject", subject)

    with tracer.start_as_current_span("emulate-email-send") as span:
        span.set_attribute("email.recipient", recipient)
        span.set_attribute("email.subject", subject)

        # Simulate processing delay
        delay = random.uniform(MIN_DELAY_SECONDS, MAX_DELAY_SECONDS)
        span.set_attribute("email.delay_seconds", round(delay, 2))
        logger.info(
            "Sending email to %s, subject: %s, estimated_delay: %.2fs",
            recipient,
            subject,
            delay,
        )
        time.sleep(delay)

        # Simulate random failure
        if random.random() < FAILURE_RATE:
            error_msg = f"Failed to send email to {recipient} (simulated SMTP timeout)"
            logger.error(error_msg)
            span.set_status(StatusCode.ERROR, error_msg)
            span.set_attribute("email.status", "failed")
            span.record_exception(Exception(error_msg))
            return jsonify({"status": "error", "message": error_msg}), 500

        logger.info("Email sent to %s, subject: %s", recipient, subject)
        span.set_attribute("email.status", "sent")

    return jsonify({"status": "sent", "to": recipient}), 200


# --- Entrypoint ---------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8081"))
    logger.info("Starting %s on port %d", SERVICE_NAME, port)
    app.run(host="0.0.0.0", port=port)
