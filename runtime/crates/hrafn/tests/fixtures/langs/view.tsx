import React from "react";

type Props = { title: string };

/** The title bar. */
export function TitleBar({ title }: Props) {
  return <h1 className="title">{title}</h1>;
}

export default class Page extends React.Component<Props> {
  render() {
    return <TitleBar title={this.props.title} />;
  }
}
