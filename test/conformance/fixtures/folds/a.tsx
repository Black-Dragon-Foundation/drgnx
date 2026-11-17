interface Props {
  name: string;
}

export function Hello(props: Props) {
  return (
    <div>
      <span>{props.name}</span>
    </div>
  );
}
