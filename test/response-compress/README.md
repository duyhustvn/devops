##  Kết quả test
- Large response
```
curl -k -s -D - -o /dev/null -H "Accept-Encoding: gzip" -w "Downloaded: %{size_downloaded} bytes\n" https://example.com/response-compress-test/api/large
HTTP/2 200 
content-type: application/json
date: Mon, 06 Apr 2026 18:33:38 GMT
content-encoding: gzip
vary: Accept-Encoding
```


- Small response
```
curl -k -s -D - -o /dev/null -H "Accept-Encoding: gzip" -w "Downloaded: %{size_downloaded} bytes\n" https://example.com/response-compress-test/api/small
HTTP/2 200 
content-type: application/json
date: Mon, 06 Apr 2026 18:33:45 GMT
content-length: 172
```