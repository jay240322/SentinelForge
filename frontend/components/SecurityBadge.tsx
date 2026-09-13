type SecurityBadgeProps = {
  value: string;
  classes: string;
};

export default function SecurityBadge({
  value,
  classes,
}: SecurityBadgeProps) {
  return (
    <span
      className={`rounded-full border px-2.5 py-1 text-xs font-medium ${classes}`}
    >
      {value}
    </span>
  );
}