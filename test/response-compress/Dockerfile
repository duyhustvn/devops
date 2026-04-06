FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY main.go .

# CGO_ENABLED=0 giúp tạo ra một binary tĩnh độc lập (không phụ thuộc vào thư viện C của OS)
# GOOS=linux đảm bảo build đúng file thực thi cho môi trường Linux
RUN CGO_ENABLED=0 GOOS=linux go build -o api-server main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /app/api-server .
EXPOSE 8080
CMD ["./api-server"]