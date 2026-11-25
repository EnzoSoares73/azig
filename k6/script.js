import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  vus: 1000,
  duration: '30s',
};

const fiftyKbObject = {
  data: 'x'.repeat(50 * 1024) // 50KB string
};

export default function() {
  let res = http.post('http://0.0.0.0:2500');
  check(res, { "status is 200": (res) => res.status === 200 });
}
