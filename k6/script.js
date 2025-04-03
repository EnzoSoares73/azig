import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  vus: 10000,
  duration: '30s',
};

export default function() {
  let res = http.get('http://0.0.0.0:2500');
  check(res, { "status is 200": (res) => res.status === 200 });
  sleep(1);
}
