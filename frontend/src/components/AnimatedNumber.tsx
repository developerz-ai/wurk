import { useCountUp } from '../hooks/useCountUp';
import { formatNumber } from '../utils';

interface AnimatedNumberProps {
  value: number;
}

// Locale-formatted integer that counts up to `value`. Rounds the in-flight
// tween so intermediate frames read as whole counts; the final frame lands
// exactly on the target.
export function AnimatedNumber(props: AnimatedNumberProps) {
  const display = useCountUp(() => props.value);
  return <>{formatNumber(Math.round(display()))}</>;
}
