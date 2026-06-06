import { useCountUp } from '../hooks/useCountUp';

interface AnimatedNumberProps {
  value: number;
}

// Locale-formatted integer that counts up to `value`. Rounds the in-flight
// tween so intermediate frames read as whole counts; the final frame lands
// exactly on the target.
export function AnimatedNumber({ value }: AnimatedNumberProps) {
  const display = useCountUp(value);
  return <>{Math.round(display).toLocaleString()}</>;
}
