package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
)

// Cấu trúc dữ liệu giả lập cho 1 bản ghi
type Record struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Status      string `json:"status"`
}

// Handler cho API trả về dữ liệu nhỏ (< 1KB)
func smallPayloadHandler(w http.ResponseWriter, r *http.Request) {
	// QUAN TRỌNG: Phải set đúng Content-Type để Envoy nhận diện được
	w.Header().Set("Content-Type", "application/json")

	// Chỉ trả về 1 bản ghi duy nhất
	record := Record{
		ID:          1,
		Name:        "Test Small Payload",
		Description: "Dữ liệu này rất nhỏ, chắc chắn dưới 1024 bytes. Envoy sẽ bỏ qua và không nén.",
		Status:      "active",
	}

	json.NewEncoder(w).Encode(record)
}

// Handler cho API trả về dữ liệu lớn (> 1KB)
func largePayloadHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// Tạo ra 15.000 bản ghi để giả lập payload 3-4MB
	var records []Record
	for i := 1; i <= 15000; i++ {
		records = append(records, Record{
			ID:          i,
			Name:        fmt.Sprintf("User Record %d", i),
			Description: "Đây là đoạn text mô tả dài để làm tăng dung lượng của file JSON. Nó lặp đi lặp lại rất nhiều lần nên Gzip sẽ nén cực kỳ hiệu quả.",
			Status:      "active",
		})
	}

	json.NewEncoder(w).Encode(records)
}

func main() {
	http.HandleFunc("/api/small", smallPayloadHandler)
	http.HandleFunc("/api/large", largePayloadHandler)

	port := ":8080"
	fmt.Printf("Server đang chạy tại http://localhost%s\n", port)

	if err := http.ListenAndServe(port, nil); err != nil {
		log.Fatalf("Lỗi khởi động server: %v", err)
	}
}
