FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod ./
RUN go mod download

COPY . .

ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -o ping-pong-app .


FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /app/ping-pong-app /ping-pong-app

USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/ping-pong-app"]
