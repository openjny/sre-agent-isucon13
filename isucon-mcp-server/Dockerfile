FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o isucon-mcp-server .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates openssh-client
COPY --from=builder /app/isucon-mcp-server /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["isucon-mcp-server"]
