FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o ssh-mcp-server .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates openssh-client
COPY --from=builder /app/ssh-mcp-server /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["ssh-mcp-server"]
